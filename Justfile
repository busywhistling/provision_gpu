# GPU_TYPE is required — pass a named preset or a full EC2 instance type.
# Run `just setup` with no argument to see the available options.
setup gpu_type='':
  fish setup-infra.fish {{gpu_type}}
  afplay /System/Library/Sounds/Glass.aiff

destroy:
  PULUMI_CONFIG_PASSPHRASE=$(op read "op://Private/Pulumi/passphrase") pulumi destroy --stack=gpu --yes
  rm -f ~/.ssh/aws_hosts
  afplay /System/Library/Sounds/Glass.aiff

refresh:
  PULUMI_CONFIG_PASSPHRASE=$(op read "op://Private/Pulumi/passphrase") pulumi refresh --stack=gpu --yes
