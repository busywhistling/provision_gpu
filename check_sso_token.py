#!/usr/bin/env python3
# Report whether the SSO access token an AWS profile depends on is still usable.
#
# Why this exists: newer AWS CLIs cache the fetched SSO *role credentials* in
# ~/.aws/cli/cache. That makes `aws sts get-caller-identity` succeed long after
# the underlying SSO access token in ~/.aws/sso/cache has expired, so a CLI
# check gives a false "already logged in". SDK-based tools such as the Pulumi
# AWS provider only read ~/.aws/sso/cache and fail there instead. The cache
# file name is sha1 of the sso-session name (or, for legacy profiles, of the
# sso start URL) — the scheme the AWS CLI itself uses.
#
# Prints one of: "ok" (valid token), "expired" (run `aws sso login`),
# "static" (profile does not use SSO, nothing to check).

import configparser
import hashlib
import json
import os
import sys
from datetime import datetime, timedelta, timezone

profile = sys.argv[1] if len(sys.argv) > 1 else "default"
# Refresh the token a little before it expires so a long pulumi run starting
# right now doesn't run past a token that dies mid-deploy.
SAFETY_MARGIN = timedelta(minutes=15)

parser = configparser.ConfigParser()
parser.read(os.path.expanduser("~/.aws/config"))

section = f"profile {profile}"
if not parser.has_section(section):
    # Profile is not in the config file (e.g. plain keys in ~/.aws/credentials).
    print("static")
    sys.exit(0)

sso_session = parser[section].get("sso_session")
if sso_session:
    if not parser.has_section(f"sso-session {sso_session}"):
        print("expired")  # broken config; make the login run surface it
        sys.exit(0)
    cache_key = sso_session
else:
    start_url = parser[section].get("sso_start_url")
    if not start_url:
        print("static")
        sys.exit(0)
    cache_key = start_url

token_file = os.path.expanduser(f"~/.aws/sso/cache/{hashlib.sha1(cache_key.encode()).hexdigest()}.json")
if not os.path.isfile(token_file):
    print("expired")
    sys.exit(0)

with open(token_file, encoding="utf-8") as f:
    token = json.load(f)

expires_at = token.get("expiresAt")
if not expires_at:
    print("expired")
    sys.exit(0)

expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
if expiry > datetime.now(timezone.utc) + SAFETY_MARGIN and token.get("accessToken"):
    print("ok")
else:
    print("expired")
