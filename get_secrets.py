import asyncio

from onepassword.client import Client, DesktopAuth

ACCOUNT_NAME = "Paramjit"


async def get_secret():
  # Connects to 1Password. Fill in your own integration name and version.
  client = await Client.authenticate(
    auth=DesktopAuth(
      # TODO: Set to your 1Password account name.
      account_name=ACCOUNT_NAME
    ),
    # TODO: Set to your own integration name and version.
    integration_name="My 1Password Integration",
    integration_version="v1.0.0",
  )

  # Retrieves a secret from 1Password. Takes a secret reference as input and returns the secret to which it points.
  value = await client.secrets.resolve("op://Private/EC2/password")
  return value


if __name__ == "__main__":
  asyncio.run(get_secret())
