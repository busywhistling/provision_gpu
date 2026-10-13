"""CUDA GPU EC2 instance setup"""

import os
import pathlib
import subprocess

import pulumi
import pulumi_aws as aws

from aws_secrets import EC2_USER_PASSWORD

_top = pathlib.Path(__file__).resolve().parent

# --- Config ---
# GPU instance type must be provided, either as a named preset or a full EC2
# instance type. Set via `just setup <type>` or
# `pulumi config set gpu:instance_type <type>`.
GPU_PRESETS = {
    "t4": "g4dn.xlarge",        # 1x T4 16GB, cheapest (~$0.53/hr)
    "a10g": "g5.xlarge",        # 1x A10G 24GB (~$1.01/hr)
    "l40s": "g6e.xlarge",       # 1x L40S 48GB (~$1.60/hr)
    "rtx6000": "g7e.2xlarge",   # 1x RTX PRO 6000 Blackwell 96GB (~$3.40+/hr)
}

# EC2 GPU instance family whitelist (family = part before the dot)
_ALLOWED_FAMILIES = (
    "g4ad", "g4dn", "g5", "g5g",
    "g6", "g6e", "g7", "g7e",
    "p3", "p4d", "p4de", "p5", "p5e", "p5en",
)


def resolve_instance_type() -> str:
    """Resolve the GPU instance type from Pulumi config (required, no default)."""
    raw = pulumi.Config("gpu").get("instance_type")
    if not raw:
        raise ValueError(
            "GPU instance type is not set. Provide one via `just setup <type>` "
            "(e.g. `just setup t4` or `just setup rtx6000`), or run "
            "`pulumi config set gpu:instance_type g7e.2xlarge`. "
            f"Named presets: {', '.join(sorted(GPU_PRESETS))}. Allowed EC2 "
            f"instance families: {', '.join(_ALLOWED_FAMILIES)}."
        )
    if raw in GPU_PRESETS:
        return GPU_PRESETS[raw]

    family = raw.split(".")[0]
    if family not in _ALLOWED_FAMILIES:
        raise ValueError(
            f"Unknown GPU instance type '{raw}'. Use one of the EC2 GPU families "
            f"({', '.join(_ALLOWED_FAMILIES)}) or a named preset "
            f"({', '.join(sorted(GPU_PRESETS))})."
        )
    return raw


# --- Key helpers ---
# The SSH key now lives in 1Password and is served via its ssh-agent socket
# (see `IdentityAgent` in ~/.ssh/config), not as ~/.ssh/id_ed25519(.pub).
ONEPASSWORD_AGENT_SOCK = (
    pathlib.Path.home()
    / "Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
)


def _dedupe(items):
    """First-seen-order deduplication."""
    seen, out = set(), []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def get_ssh_public_key() -> str:
    """Return the SSH public key for the EC2 KeyPair.

    Resolution order:
    1. `GPU_SSH_PUBKEY` env var (literal key, e.g. "ssh-ed25519 AAAA...").
    2. Any legacy pub key file on disk (e.g. ~/.ssh/id_ed25519.pub), if present.
    3. The first key offered by the SSH agent (1Password by default, overridable
       via `SSH_AUTH_SOCK`).
    """
    env_key = os.environ.get("GPU_SSH_PUBKEY", "").strip()
    if env_key:
        return env_key

    for candidate in ("~/.ssh/id_ed25519.pub", "~/.ssh/id_ed25519.pub"):
        path = pathlib.Path(candidate).expanduser()
        if path.is_file():
            return path.read_text().strip()

    # SSH_AUTH_SOCK is often set on macOS to the default Apple agent (which
    # has no keys), so also consult the 1Password agent as a fallback.
    socks = _dedupe(
        s for s in (
            os.environ.get("SSH_AUTH_SOCK"),
            str(ONEPASSWORD_AGENT_SOCK),
        ) if s
    )
    for sock in socks:
        result = subprocess.run(
            ["ssh-add", "-L"],
            env={**os.environ, "SSH_AUTH_SOCK": sock},
            capture_output=True,
            text=True,
            check=False,
        )
        keys = [line for line in result.stdout.splitlines() if line.strip()]
        if keys:
            return keys[0]

    raise RuntimeError(
        "No SSH public key available. Unlock 1Password so its ssh-agent "
        "serves a key (check with `ssh-add -L`), or set GPU_SSH_PUBKEY."
    )


def setup_instance():
    """Provision the GPU instance and supporting resources.

    Returns (ami, sg, key_pair, instance).
    """
    instance_type = resolve_instance_type()
    print(f"Provisioning GPU instance type: {instance_type}")

    # --- Startup Script ---
    _user_data_template = _top.parent / "setup-host.sh"
    user_data = _user_data_template.read_text().replace(
        "set -e",
        f"set -e\nexport EC2_USER_PASSWORD='{EC2_USER_PASSWORD}'",
        1,
    )

    # Deep Learning AMI (Amazon Linux 2) - has CUDA/drivers pre-installed
    # Find the latest: https://aws.amazon.com/machine-learning/amis/
    # aws ec2 describe-images --region us-east-1 --owners amazon --filters 'Name=name,Values=Deep Learning Base AMI with Single CUDA (Ubuntu 24.04) ????????' 'Name=state,Values=available' --query 'reverse(sort_by(Images, &CreationDate))[:1].ImageId' --output text
    ami = aws.ec2.get_ami(
        most_recent=True,
        owners=["amazon"],
        filters=[
            aws.ec2.GetAmiFilterArgs(
                name="name",
                values=["Deep Learning Base AMI with Single CUDA (Ubuntu 24.04) ????????"],
            ),
            aws.ec2.GetAmiFilterArgs(
                name="state",
                values=["available"],
            ),
        ],
    )

    # --- Security Group: allow SSH ---
    sg = aws.ec2.SecurityGroup(
        "gpu-security-group",
        description="Allow SSH",
        ingress=[
            aws.ec2.SecurityGroupIngressArgs(
                protocol="tcp",
                from_port=22,
                to_port=22,
                cidr_blocks=["0.0.0.0/0"],  # Restrict to your IP in production!
            )
        ],
        egress=[
            aws.ec2.SecurityGroupEgressArgs(
                protocol="-1",
                from_port=0,
                to_port=0,
                cidr_blocks=["0.0.0.0/0"],
            )
        ],
    )

    # --- Key Pair (optional but recommended for SSH) ---
    # Public key comes from the 1Password ssh-agent (see get_ssh_public_key).
    key_pair = aws.ec2.KeyPair(
        "gpu-ssh-key",
        public_key=get_ssh_public_key(),
    )

    # --- GPU Instance ---
    instance = aws.ec2.Instance(
        "gpu-instance",
        instance_type=instance_type,
        ami=ami.id,
        vpc_security_group_ids=[sg.id],
        key_name=key_pair.key_name,  # Uncomment after adding your key above
        root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
            volume_size=100,  # GB — DL AMIs need space
            volume_type="gp3",
        ),
        user_data=user_data,
        tags={"Name": "gpu-instance"},
    )

    return ami, sg, key_pair, instance
