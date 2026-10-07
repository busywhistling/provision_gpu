"""CUDA GPU EC2 instance setup"""

import pathlib

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
    # Replace with your actual public key, or remove key_name to skip SSH
    key_pair = aws.ec2.KeyPair(
        "gpu-ssh-key",
        public_key=open("~/.ssh/id_ed25519.pub").read(),
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
