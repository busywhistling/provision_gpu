setup:
  aws sso login --profile default

up:
  PULUMI_CONFIG_PASSPHRASE=$(op read "op://Private/Pulumi/passphrase") pulumi up --stack gpu

setup_host:
  ssh ubuntu@203.0.113.10 "EC2_USER_PASSWORD='(op read op://Private/EC2/password)' bash -s" < setup-host.sh

destroy:
  PULUMI_CONFIG_PASSPHRASE=$(op read "op://Private/Pulumi/passphrase") pulumi destroy --stack=gpu
