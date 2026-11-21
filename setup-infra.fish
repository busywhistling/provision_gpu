#!/usr/bin/env fish

# --- Config ---
set AWS_PROFILE "default"
set PULUMI_STACK "gpu"
set SSH_USER "ubuntu"
set SETUP_SCRIPT "setup-host.sh"
set SSH_TIMEOUT 300
# Fail SSH connections fast instead of hanging for minutes (e.g. probing an
# instance that drops again mid-reboot), and bail out of dead connections.
set SSH_OPTS -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3

# --- Helper: print GPU instance type usage (presets + EC2 families) ---
function print_gpu_usage --description "Show available GPU instance type options"
  echo "Usage: just setup <gpu_type>"
  echo ""
  echo "Named presets:"
  echo "  t4       g4dn.xlarge    1x NVIDIA T4 16 GB                 (~\$0.53/hr)"
  echo "  a10g     g5.xlarge      1x NVIDIA A10G 24 GB               (~\$1.01/hr)"
  echo "  l40s     g6e.xlarge     1x NVIDIA L40S 48 GB               (~\$1.60/hr)"
  echo "  rtx6000  g7e.2xlarge    1x RTX PRO 6000 Blackwell 96 GB    (~\$3.40+/hr)"
  echo ""
  echo "Or any full EC2 GPU instance type (validated against these families):"
  echo "  g4ad g4dn g5 g5g g6 g6e g7 g7e p3 p4d p4de p5 p5e p5en"
  echo ""
  echo "Examples:"
  echo "  just setup t4"
  echo "  just setup rtx6000"
  echo "  just setup g7e.12xlarge   (2x RTX PRO 6000)"
end

# --- Require the GPU instance type argument ---
set gpu_type $argv[1]
if test -z "$gpu_type"
  echo "Error: GPU instance type is required — there is no default."
  echo ""
  print_gpu_usage
  exit 1
end

# --- Ensure we're in the script's directory ---
cd (dirname (status --current-filename))

# --- Helper: wait for SSH port to be reachable ---
function wait_for_ssh --description "Wait until SSH port is open on the given host"
  set -l host $argv[1]
  set -l start_time (date +%s)
  while true
    set -l elapsed (math (date +%s) - $start_time)
    if test $elapsed -ge $SSH_TIMEOUT
      echo "Error: SSH did not become available within $SSH_TIMEOUT seconds."
      return 1
    end
    if nc -z -w 5 $host 22 2>/dev/null
      return 0
    end
    echo "  Waiting for SSH... ($elapsed s elapsed)"
    sleep 10
  end
end

# --- 1. Check AWS SSO login ---
# Use the profile Pulumi will actually run with (aws:profile in the stack
# config, falling back to the script default), not $AWS_PROFILE. Checking the
# wrong profile can pass while Pulumi's own profile has an expired SSO session.
set pulumi_profile (uv run pulumi config get aws:profile --stack $PULUMI_STACK 2>/dev/null)
if test -z "$pulumi_profile"
  set pulumi_profile $AWS_PROFILE
end

echo "Checking AWS SSO login for profile '$pulumi_profile'..."

# NOTE: `aws sts get-caller-identity` can succeed via the CLI's own role-credential
# cache (~/.aws/cli/cache) even after the SSO access token that the Pulumi AWS
# provider reads (~/.aws/sso/cache) has expired — which then errors with
# "Failed to refresh cached SSO credentials". So for SSO profiles we check the
# SSO token file itself (check_sso_token.py) instead of a CLI call.
set sso_state (python3 (status dirname)/check_sso_token.py $pulumi_profile 2>/dev/null)
switch $sso_state
  case "expired"
    echo "AWS SSO session expired. Logging in (browser will open)..."
    aws sso login --profile $pulumi_profile
    or exit 1
    echo "AWS SSO login successful."
  case "static"
    echo "Profile '$pulumi_profile' does not use SSO; no SSO login needed."
  case "*"
    if test -z "$sso_state"
      # Checker could not run — fall back to the CLI check.
      if not aws sts get-caller-identity --profile $pulumi_profile >/dev/null 2>&1
        echo "AWS SSO session expired or not logged in. Logging in..."
        aws sso login --profile $pulumi_profile
        or exit 1
        echo "AWS SSO login successful."
      end
    else
      echo "AWS SSO already logged in."
    end
end

# --- 2. Get Pulumi passphrase and EC2 password from 1Password ---
# Secret references come from the environment, so no vault paths are hardcoded
# in this public repo. Load .env (dotenv syntax, which fish can't source) into
# the environment first; variables already set win over the file.
if test -f .env
  for line in (string match -rv '^\s*(#|$)' < .env)
    set -l kv (string split -m1 = -- $line)
    set -q $kv[1]; and continue
    set -gx $kv[1] (string trim -c '"' -- $kv[2])
  end
end

for var in PULUMI_PASSPHRASE_SECRET_REF EC2_PASSWORD_SECRET_REF
  if not set -q $var
    echo "Error: $var is not set. Copy .env.sample to .env and point both secret references at your own 1Password items."
    exit 1
  end
end

echo "Retrieving secrets from 1Password..."
set pulumi_passphrase (op read $PULUMI_PASSPHRASE_SECRET_REF)
or exit 1
set -x PULUMI_CONFIG_PASSPHRASE $pulumi_passphrase
set ec2_password (op read $EC2_PASSWORD_SECRET_REF)
or exit 1
set -x EC2_USER_PASSWORD $ec2_password

# --- 2b. Create the stack on first run ---
# With the passphrase secrets provider, stack init writes a fresh
# encryptionsalt into Pulumi.<stack>.yaml. The salt is generated here, not
# stored in the repository.
if not uv run pulumi stack select $PULUMI_STACK >/dev/null 2>&1
  echo "Stack '$PULUMI_STACK' not found; creating it..."
  uv run pulumi stack init $PULUMI_STACK --secrets-provider passphrase
  or exit 1
end

# --- 3. Run pulumi up ---
echo "Setting GPU instance type to '$gpu_type'..."
uv run pulumi config set --stack $PULUMI_STACK gpu:instance_type $gpu_type
or exit 1

echo "Running pulumi..."
uv run pulumi up --stack $PULUMI_STACK --yes
or exit 1

# --- 4. Get the public IP from pulumi output ---
echo "Retrieving instance public IP..."
set public_ip (pulumi stack output public_ip --stack $PULUMI_STACK)
or exit 1
echo "Instance public IP: $public_ip"

# --- 4b. Register the instance in ~/.ssh so plain `ssh aws` works ---
# The instance is ephemeral, so the alias's IP changes on every deploy:
# rewrite a managed include file each run instead of a static config entry.
# Works for ssh/scp/rsync/VS Code Remote-SSH, and survives without Pulumi.
set -l ssh_dir $HOME/.ssh
set -l aws_hosts_file $ssh_dir/aws_hosts

mkdir -p $ssh_dir
# Drop any stale host key for this IP first — short-lived instances can
# recycle IPs, and a leftover key would block connecting with accept-new.
ssh-keygen -R $public_ip > /dev/null 2>&1

begin
  echo "# Managed by provision_gpu/setup-infra.fish — do not edit"
  echo "Host aws"
  echo "  HostName $public_ip"
  echo "  User $SSH_USER"
  echo "  IdentityAgent ~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  echo "  StrictHostKeyChecking accept-new"
end > $aws_hosts_file
chmod 600 $aws_hosts_file

# One-time: include the managed file from ~/.ssh/config (prepend, so it
# takes effect before any later Host * block).
if not test -f $ssh_dir/config
  echo "Include ~/.ssh/aws_hosts" > $ssh_dir/config
  chmod 600 $ssh_dir/config
else if not grep -qF ".ssh/aws_hosts" $ssh_dir/config
  set -l tmp (mktemp)
  echo "Include ~/.ssh/aws_hosts" > $tmp
  cat $ssh_dir/config >> $tmp
  mv $tmp $ssh_dir/config
  chmod 600 $ssh_dir/config
end
echo "SSH alias registered: ssh aws → ubuntu@$public_ip"

# --- 5. Wait for SSH to be reachable ---
echo "Waiting for SSH to be available at $public_ip:22..."
wait_for_ssh $public_ip
or exit 1
echo "SSH port is open!"

sleep 5

# --- 5b. Copy the chezmoi source repo to the instance ---
# Uploaded before setup-host.sh runs so its clone step can pick it up.
# Idempotent: skip the upload when the remote copy is already at the same
# commit as the local one (both are git repos, so HEAD is the fingerprint).
# If the local repo has new commits, the hash differs and it re-uploads.
set -l chezmoi_src $HOME/.local/share/chezmoi_for_vm.git
set -l local_head (git -C $chezmoi_src rev-parse HEAD 2>/dev/null)
set -l remote_head (ssh $SSH_OPTS $SSH_USER@$public_ip \
    "git -C ~/.local/chezmoi.git rev-parse HEAD 2>/dev/null" < /dev/null)
if test -n "$local_head"; and test "$local_head" = "$remote_head"
  echo "chezmoi.git already up to date (HEAD $local_head); skipping upload."
else
  echo "Uploading chezmoi source repo to $SSH_USER@$public_ip:~/.local/chezmoi.git..."
  ssh $SSH_OPTS $SSH_USER@$public_ip "mkdir -p ~/.local"
  scp $SSH_OPTS -r $chezmoi_src $SSH_USER@$public_ip:.local/chezmoi.git
  or exit 1
end

# --- 5c. Copy Ghostty's terminfo entry to the instance ---
# Method 1 from the Ghostty docs (https://ghostty.org/docs/help/terminfo):
# reconstruct the terminfo entry from the local terminfo database with
# `infocmp -x xterm-ghostty` and compile it into the instance's system
# database with `tic -x`. No app-bundle paths — this works on any OS with
# Ghostty's terminfo visible to infocmp. (If the local ncurses is too old,
# install Homebrew ncurses; `tic` may warn about the description
# field being an alias on older versions — ignorable.)
# The docs' one-liner streams infocmp straight into ssh (`infocmp ... |
# ssh host -- tic -x -`), but we can't attach stdin to this session —
# fish's shell-init on the instance would consume it. So infocmp output
# goes base64-encoded through the command line, and tic compiles a file.
function _ghostty_terminfo_source --description "Terminfo source for xterm-ghostty, via infocmp"
  for cmp in infocmp /opt/homebrew/opt/ncurses/bin/infocmp /usr/local/opt/ncurses/bin/infocmp
    if command -q $cmp
      set -l src ($cmp -x xterm-ghostty 2>/dev/null)
      if test (count $src) -gt 0
        string join \n -- $src
        return 0
      end
    end
  end
  return 1
end

# Idempotent: skip if the instance already has the xterm-ghostty entry
# compiled into its system terminfo database.
echo "Installing Ghostty terminfo on the instance..."
set -l terminfo_present (ssh $SSH_OPTS $SSH_USER@$public_ip \
    "infocmp -x xterm-ghostty > /dev/null 2>&1 && echo ok" < /dev/null 2>/dev/null)
if test "$terminfo_present" = "ok"
  echo "xterm-ghostty terminfo already installed; skipping."
else if not _ghostty_terminfo_source > /dev/null
  echo "No xterm-ghostty terminfo found locally (is Ghostty installed?); skipping."
else
  set -l b64 (_ghostty_terminfo_source | base64 | tr -d '\n')
  ssh $SSH_OPTS $SSH_USER@$public_ip \
    "echo $b64 | base64 -d > /tmp/ghostty.terminfo \
         && sudo tic -x /tmp/ghostty.terminfo \
         && rm -f /tmp/ghostty.terminfo \
         && infocmp -x xterm-ghostty > /dev/null && echo terminfo-ok" \
    < /dev/null
end

# --- 6. SSH and run setup-host.sh ---
# Copy the script to the instance and run it from a file instead of piping
# it over stdin. Reason: once the login shell is fish and ~/.config/fish/
# config.fish contains a bare `source` (bisecting a brew-less box), fish's
# shell-init can read and consume stdin, which would corrupt the streamed
# script. Reading from /tmp/setup-host.sh is independent of stdin.
# Stream output live (so a hang is visible) and tee it to a file so we can
# still detect the "REBOOTING" marker afterwards.
# We can't rely on SSH exit code: `sudo reboot` may return 0 before the
# machine goes down, making SSH exit cleanly even though a reboot is pending.
echo "Running setup-host.sh on the remote instance..."
scp $SSH_OPTS $SETUP_SCRIPT $SSH_USER@$public_ip:/tmp/setup-host.sh
or exit 1
set ssh_log_file (mktemp)
ssh $SSH_OPTS $SSH_USER@$public_ip \
  "env EC2_USER_PASSWORD='$ec2_password' bash /tmp/setup-host.sh < /dev/null" 2>&1 | tee $ssh_log_file
set ssh_exit $pipestatus[1]
set ssh_output (cat $ssh_log_file)
rm $ssh_log_file

if test $ssh_exit -ne 0 -a $ssh_exit -ne 255
  echo "Error: setup-host.sh failed with exit code $ssh_exit."
  exit 1
end

# --- 7. Detect reboot from output and wait accordingly ---
if string match -q "*REBOOTING*" -- (string collect -- $ssh_output)
  echo "Reboot triggered, waiting for SSH to go down..."

  # Wait for SSH to go down (reboot may not have started yet)
  set down_start (date +%s)
  while true
    set elapsed (math (date +%s) - $down_start)
    if test $elapsed -ge 60
      echo "SSH still up after 60s — reboot may have already completed."
      break
    end
    if not nc -z -w 5 $public_ip 22 2>/dev/null
      echo "SSH is down (rebooting)..."
      break
    end
    sleep 5
  end

  echo "Waiting for SSH to come back..."
  wait_for_ssh $public_ip
  or exit 1
  echo "SSH is back up! Reboot complete."
else
  echo "setup-host.sh completed (no reboot needed)."
end

# --- 8. Verify setup completed on the remote ---
sleep 5
echo "Verifying setup completion..."
set verify (ssh $SSH_OPTS $SSH_USER@$public_ip "test -f /var/lib/.setup-host-done && echo ok || echo fail" 2>/dev/null; or echo "fail")
if test "$verify" != "ok"
  echo "Error: Setup flag not found on remote. Setup may not have completed."
  exit 1
end

echo "Setup complete! Instance is ready at $public_ip"
echo ""
echo "You can ssh using:"
echo "ssh ubuntu@$public_ip"
