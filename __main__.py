"""An AWS Python Pulumi program"""

import asyncio
import concurrent.futures
import pathlib

import pulumi
import pulumi_aws as aws

from get_secrets import get_secret

PASSWORD = concurrent.futures.ThreadPoolExecutor().submit(
    lambda: asyncio.run(get_secret())
).result()

# --- Startup Script ---
_user_data_template = pathlib.Path(__file__).parent / "setup-host.sh"
user_data = _user_data_template.read_text().replace(
    "set -e",
    f"set -e\nexport EC2_USER_PASSWORD='{PASSWORD}'",
    1,
)

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
