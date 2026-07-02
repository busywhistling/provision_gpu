setup:
  fish setup-infra.fish

destroy:
  PULUMI_CONFIG_PASSPHRASE=$(op read "op://Private/Pulumi/passphrase") pulumi destroy --stack=gpu
