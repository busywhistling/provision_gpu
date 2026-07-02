# AWS GPU EC2 Instance (Pulumi)

Provision a GPU EC2 instance on AWS for deep learning / GPU work using Pulumi and Python.

## Overview

This project creates a `g4dn.xlarge` GPU instance in `eu-central-1` using the **Deep Learning Base AMI with Single CUDA (Ubuntu 24.04)**, with:

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
- Python 3.13 or later installed.
- [uv](https://docs.astral.sh/uv/) installed.
- Pulumi CLI already installed and logged in.
- An SSH public key at `~/.ssh/id_ed25519.pub` (or update the path in `__main__.py`).

## Getting Started

1. Preview the planned changes:
   ```bash
   pulumi preview
   ```

2. Deploy the stack:
   ```bash
   pulumi up
   ```

3. SSH into the instance once deployed:
   ```bash
   ssh ubuntu@$(pulumi stack output public_ip)
   ```

4. Tear down when finished:
   ```bash
   pulumi destroy
   ```

## Configuration

Edit `__main__.py` to customize:

- `INSTANCE_TYPE` — GPU instance type (default: `g4dn.xlarge`; alternatives: `g5.xlarge`, `p3.2xlarge`)
- `REGION` — AWS region (default: `eu-central-1`)
- `PASSWORD` — password for the `ubuntu` user
- Key pair public key path

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
