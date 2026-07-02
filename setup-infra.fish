#!/usr/bin/env fish

# --- Config ---
set AWS_PROFILE "default"
set PULUMI_STACK "gpu"
set SSH_USER "ubuntu"
set SETUP_SCRIPT "setup-host.sh"
set SSH_TIMEOUT 300

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
echo "Checking AWS SSO login for profile '$AWS_PROFILE'..."

if not aws sts get-caller-identity --profile $AWS_PROFILE >/dev/null 2>&1
    echo "AWS SSO session expired or not logged in. Logging in..."
    aws sso login --profile $AWS_PROFILE
    or exit 1
    echo "AWS SSO login successful."
else
    echo "AWS SSO already logged in."
end

# --- 2. Get Pulumi passphrase from 1Password ---
echo "Retrieving Pulumi passphrase from 1Password..."
set pulumi_passphrase (op read "op://Private/Pulumi/passphrase")
or exit 1

# --- 3. Run pulumi up ---
echo "Running pulumi up..."
set -x PULUMI_CONFIG_PASSPHRASE $pulumi_passphrase
uv run pulumi up --stack $PULUMI_STACK --yes
or exit 1

# --- 4. Get the public IP from pulumi output ---
echo "Retrieving instance public IP..."
set public_ip (pulumi stack output public_ip --stack $PULUMI_STACK)
or exit 1
echo "Instance public IP: $public_ip"

# --- 5. Wait for SSH to be reachable ---
echo "Waiting for SSH to be available at $public_ip:22..."
wait_for_ssh $public_ip
or exit 1
echo "SSH port is open!"

sleep 5

# --- 6. Get EC2 user password from 1Password ---
echo "Retrieving EC2 user password from 1Password..."
set ec2_password (op read "op://Private/EC2/password")
or exit 1

# --- 7. SSH and run setup-host.sh ---
# Capture output to detect reboot from "REBOOTING" marker.
# We can't rely on SSH exit code: `sudo reboot` may return 0 before the
# machine goes down, making SSH exit cleanly even though a reboot is pending.
echo "Running setup-host.sh on the remote instance..."
set ssh_output (ssh -o StrictHostKeyChecking=accept-new $SSH_USER@$public_ip "EC2_USER_PASSWORD='$ec2_password' bash -s" < $SETUP_SCRIPT 2>&1; or echo "")
set ssh_exit $status

# Print what we captured so the user sees the remote progress
printf '%s\n' $ssh_output

if test $ssh_exit -ne 0 -a $ssh_exit -ne 255
    echo "Error: setup-host.sh failed with exit code $ssh_exit."
    exit 1
end

# --- 8. Detect reboot from output and wait accordingly ---
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

# --- 9. Verify setup completed on the remote ---
sleep 5
echo "Verifying setup completion..."
set verify (ssh -o StrictHostKeyChecking=accept-new $SSH_USER@$public_ip "test -f /var/lib/.setup-host-done && echo ok || echo fail" 2>/dev/null; or echo "fail")
if test "$verify" != "ok"
    echo "Error: Setup flag not found on remote. Setup may not have completed."
    exit 1
end

echo "Setup complete! Instance is ready at $public_ip"
