#!/usr/bin/env fish

# --- Config ---
set AWS_PROFILE "default"
set PULUMI_STACK "gpu"
set SSH_USER "ubuntu"
set SETUP_SCRIPT "setup-host.sh"
set SSH_TIMEOUT 300

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
echo "Checking AWS SSO login for profile '$AWS_PROFILE'..."

if not aws sts get-caller-identity --profile $AWS_PROFILE >/dev/null 2>&1
    echo "AWS SSO session expired or not logged in. Logging in..."
    aws sso login --profile $AWS_PROFILE
    or exit 1
    echo "AWS SSO login successful."
else
    echo "AWS SSO already logged in."
end

# --- 2. Get Pulumi passphrase and EC2 password from 1Password ---
echo "Retrieving secrets from 1Password..."
set pulumi_passphrase (op read "op://Private/Pulumi/passphrase")
or exit 1
set ec2_password (op read "op://Private/EC2/password")
or exit 1
set -x EC2_USER_PASSWORD $ec2_password

# --- 3. Run pulumi up ---
echo "Setting GPU instance type to '$gpu_type'..."
uv run pulumi config set --stack $PULUMI_STACK gpu:instance_type $gpu_type
or exit 1

echo "Running pulumi..."
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

# --- 5b. Copy the chezmoi source repo to the instance ---
# Uploaded before setup-host.sh runs so its clone step can pick it up.
echo "Uploading chezmoi source repo to $SSH_USER@$public_ip:~/.local/chezmoi.git..."
ssh -o StrictHostKeyChecking=accept-new $SSH_USER@$public_ip "mkdir -p ~/.local"
scp -r -o StrictHostKeyChecking=accept-new $HOME/.local/share/chezmoi_for_vm.git $SSH_USER@$public_ip:.local/chezmoi.git
or exit 1

# --- 6. SSH and run setup-host.sh ---
# Stream output live (so a hang is visible) and tee it to a file so we can
# still detect the "REBOOTING" marker afterwards.
# We can't rely on SSH exit code: `sudo reboot` may return 0 before the
# machine goes down, making SSH exit cleanly even though a reboot is pending.
echo "Running setup-host.sh on the remote instance..."
set ssh_log_file (mktemp)
ssh -o StrictHostKeyChecking=accept-new $SSH_USER@$public_ip \
    "EC2_USER_PASSWORD='$ec2_password' bash -s" < $SETUP_SCRIPT 2>&1 | tee $ssh_log_file
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
set verify (ssh -o StrictHostKeyChecking=accept-new $SSH_USER@$public_ip "test -f /var/lib/.setup-host-done && echo ok || echo fail" 2>/dev/null; or echo "fail")
if test "$verify" != "ok"
    echo "Error: Setup flag not found on remote. Setup may not have completed."
    exit 1
end

echo "Setup complete! Instance is ready at $public_ip"
echo ""
echo "You can ssh using:"
echo "ssh ubuntu@$public_ip"
