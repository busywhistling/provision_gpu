"""An AWS Python Pulumi program"""

import textwrap

import pulumi
import pulumi_aws as aws

PASSWORD = "yourpasswordhere"

# --- Startup Script ---
user_data = textwrap.dedent(f"""\
#!/bin/bash
set -e
exec > /var/log/user-data.log 2>&1   # Log everything for debugging

echo "=== Starting setup ==="

# Set a password for the ubuntu user so Homebrew's sudo prompts work
# Generate hash and set password in one shot, bypassing PAM entirely
HASHED=$(openssl passwd -6 '{PASSWORD}')
sudo usermod -p "$HASHED" ubuntu

# Example: system updates
sudo add-apt-repository ppa:fish-shell/release-4 -y
sudo apt update -y
sudo apt upgrade -y

# Example: install packages via brew
sudo apt install fish nvidia-cuda-toolkit -y
sudo chsh -s /usr/bin/fish ubuntu

sudo apt autoremove -y

fish << 'EOF'
  # Install brew
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Setup brew completions in fish shell
  echo >> /home/ubuntu/.config/fish/config.fish
  echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"' >> /home/ubuntu/.config/fish/config.fish
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"

  # Install fisher
  curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher
  # fisher install IlanCosman/tide@v6

  brew install neovim yazi btop fastfetch duf uv
EOF

# The above EOF needs to be aligned to the very left, and has to be the only
# line, with no trailing whitespace

# Delete licenses and unneeded files
rm BUILD_FROM_SOURCE_PACKAGES_LICENCES LINUX_PACKAGES_LICENSES LINUX_PACKAGES_LIST OSSNvidiaDriver_v595.71.05_license.txt
rm -rf nvidia-acknowledgements gds-nvidia-fs

printf "\nREBOOTING\n"

echo "=== Setup complete ==="
sudo reboot
""")

# --- Config ---
# GPU instance types: g4dn.xlarge (cheapest, ~$0.526/hr), g5.xlarge, p3.2xlarge
INSTANCE_TYPE = "g4dn.xlarge"
REGION = "eu-central-1"

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
  instance_type=INSTANCE_TYPE,
  ami=ami.id,
  vpc_security_group_ids=[sg.id],
  key_name=key_pair.key_name,  # Uncomment after adding your key above
  root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
    volume_size=100,  # GB — DL AMIs need space
    volume_type="gp3",
  ),
  tags={"Name": "gpu-instance"},
)

# --- Outputs ---
pulumi.export("instance_id", instance.id)
pulumi.export("public_ip", instance.public_ip)
pulumi.export("ami_used", ami.id)
