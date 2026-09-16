import asyncio
import concurrent.futures
import os

from dotenv import load_dotenv
from onepassword.client import Client, DesktopAuth

load_dotenv()

ACCOUNT_NAME = os.environ["ONEPASSWORD_ACCOUNT_NAME"]
EC2_PASSWORD_SECRET_REF = os.environ["EC2_PASSWORD_SECRET_REF"]


_client = None


async def _get_client():
  # Connects to 1Password. Fill in your own integration name and version.
  global _client
  if _client is None:
    _client = await Client.authenticate(
      auth=DesktopAuth(
        # TODO: Set to your 1Password account name.
        account_name=ACCOUNT_NAME
      ),
      # TODO: Set to your own integration name and version.
      integration_name="My 1Password Integration",
      integration_version="v1.0.0",
    )
  return _client


async def get_secret():
  client = await _get_client()
  # Retrieves a secret from 1Password. Takes a secret reference as input and returns the secret to which it points.
  value = await client.secrets.resolve(EC2_PASSWORD_SECRET_REF)
  return value


def _resolve_password() -> str:
  # Prefer the password exported by setup-infra.fish (already resolved via the
  # `op` CLI) so the 1Password desktop-app unlock isn't requested a second time.
  if env_password := os.environ.get("EC2_USER_PASSWORD"):
    return env_password
  # Pulumi's language host runs the program inside an active event loop,
  # so asyncio.run() must be invoked from a separate thread.
  executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
  try:
    return executor.submit(asyncio.run, get_secret()).result()
  finally:
    executor.shutdown(wait=False)


EC2_USER_PASSWORD = _resolve_password()


if __name__ == "__main__":
  print(EC2_USER_PASSWORD)
