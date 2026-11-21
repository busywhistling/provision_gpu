# Secret references are read from .env so no vault paths live in this repo.
set dotenv-load

# GPU_TYPE is required — pass a named preset or a full EC2 instance type.
# Run `just setup` with no argument to see the available options.
setup gpu_type='':
  fish setup-infra.fish {{gpu_type}}
  afplay /System/Library/Sounds/Glass.aiff

destroy:
  PULUMI_CONFIG_PASSPHRASE=$(op read "$PULUMI_PASSPHRASE_SECRET_REF") pulumi destroy --stack=gpu --yes
  rm -f ~/.ssh/aws_hosts
  afplay /System/Library/Sounds/Glass.aiff

refresh:
  PULUMI_CONFIG_PASSPHRASE=$(op read "$PULUMI_PASSPHRASE_SECRET_REF") pulumi refresh --stack=gpu --yes
