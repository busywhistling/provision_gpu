# AWS GPU EC2 Instance (Pulumi)

Provision a GPU EC2 instance on AWS for deep learning / GPU work using Pulumi and Python.

## Overview

This project creates a GPU EC2 instance in `eu-central-1` using the **Deep Learning Base AMI with Single CUDA (Ubuntu 24.04)**. The GPU instance type must be supplied at deploy time via `just setup <type>` (see Configuration) — e.g. `g4dn.xlarge` (T4) or `g7e.2xlarge` (RTX PRO 6000 Blackwell), with:

- SSH key pair and security group allowing SSH access
- 100 GB gp3 root volume
- A user-data startup script that:
  - Sets a password for the `ubuntu` user
  - Installs `fish` shell and `nvidia-cuda-toolkit`
  - Sets up Homebrew, fisher, and dev tools (`neovim`, `yazi`, `btop`, `fastfetch`, `duf`, `uv`)
  - Reboots the instance after setup

## Prerequisites

- An AWS account with permissions to create EC2 instances, security groups, and key pairs.
- AWS credentials configured in your environment (via AWS CLI or environment variables).
- Python 3.14 or later installed.
- [uv](https://docs.astral.sh/uv/) installed.
- Pulumi CLI already installed and logged in.
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) if you use the provided `Justfile` and `setup-infra.fish`. They read `op://Private/Pulumi/passphrase` and `op://Private/EC2/password` — point these at your own secret references.
- An SSH key available to your SSH agent (verify with `ssh-add -L`). Alternatively, set `GPU_SSH_PUBKEY` to a literal public key.

## Getting Started

1. Deploy the stack (shows the diff and asks for confirmation before applying):
   ```bash
   just setup g7e.2xlarge
   ```

2. SSH into the instance once deployed:
   ```bash
   ssh ubuntu@$(pulumi stack output public_ip)
   ```

3. Tear down when finished:
   ```bash
   just destroy
   ```

## Configuration

The GPU instance type is required — there is no default. Pass it to `just setup`:

```
just setup <type>
```

where `<type>` is either a named preset or a full EC2 instance type:

| Preset | Instance type | GPU | Notes |
|---|---|---|---|
| `t4` | `g4dn.xlarge` | 1× T4 (16 GB) | Cheapest, ~$0.53/hr |
| `a10g` | `g5.xlarge` | 1× A10G (24 GB) | ~$1.01/hr |
| `l40s` | `g6e.xlarge` | 1× L40S (48 GB) | ~$1.60/hr |
| `rtx6000` | `g7e.2xlarge` | 1× RTX PRO 6000 Blackwell (96 GB) | ~$3.40+/hr, available in `eu-central-1` |

Full EC2 types from the GPU families (`g4ad`, `g4dn`, `g5`, `g5g`, `g6`, `g6e`, `g7`, `g7e`, `p3`, `p4d`, `p4de`, `p5`, `p5e`, `p5en`) are also accepted, e.g. `just setup g7e.12xlarge` for 2× RTX PRO 6000. The value is validated and stored as Pulumi config (`gpu:instance_type`); changing it replaces the EC2 instance.

Other settings live in `src/cuda_instance.py` / `src/main.py`:
- `GPU_SSH_PUBKEY` — optional literal public key for the EC2 key pair; otherwise the first key offered by the SSH agent is used, falling back to `~/.ssh/id_ed25519.pub`
- `EC2_USER_PASSWORD` — password for the `ubuntu` user, resolved by `src/aws_secrets.py` from the environment or from 1Password via `ONEPASSWORD_ACCOUNT_NAME` and `EC2_PASSWORD_SECRET_REF` in `.env` (see `.env.sample`)

The Pulumi stack is `gpu` (`Pulumi.gpu.yaml`), with `aws:region` and `aws:profile` stored there. On the first `just setup` the stack is created if needed, and Pulumi writes a freshly generated `encryptionsalt` into that file — the salt is local, not part of the repository, and safe to keep once created.

## Outputs

The stack exports:

- `instance_id` — the EC2 instance ID
- `public_ip` — the instance's public IP address
- `ami_used` — the AMI ID used for the instance

Retrieve outputs with:
```bash
pulumi stack output public_ip
```

## Notes

- The SSH security group allows access from `0.0.0.0/0`. Restrict to your IP in production.
- The user-data script reboots the instance after setup. Allow a few minutes after `pulumi up` before connecting.

## License

MIT — see [LICENSE](LICENSE).
