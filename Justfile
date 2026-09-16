setup:
  fish setup-infra.fish
  afplay /System/Library/Sounds/Glass.aiff

destroy:
  PULUMI_CONFIG_PASSPHRASE=$(op read "op://Private/Pulumi/passphrase") pulumi destroy --stack=gpu --yes
  afplay /System/Library/Sounds/Glass.aiff
