#!/bin/bash
set -e

# Never prompt over SSH: no needrestart TUI, no dpkg conffile dialogs.
# (needrestart would otherwise hang waiting on stdin and, because this
# script is piped via `bash -s`, eat the rest of the script as input.)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
CONF_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
if [ "$(id -u)" -eq 0 ]; then
  exec > /var/log/user-data.log 2>&1   # Log everything for debugging
fi

SETUP_FLAG=/var/lib/.setup-host-done
MARK_FILE=/var/lib/setup-host-state

record_step() {
  echo "$1" | sudo tee -a "$MARK_FILE" > /dev/null
}
step_done() {
  sudo grep -qx "$1" "$MARK_FILE" 2>/dev/null
}

# First-boot unattended-upgrades may hold the dpkg lock (e.g. right after `apt-get update`).
# Rather than failing, wait for it to finish before touching apt.
wait_for_apt_locks() {
  local waited=0
  while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
        /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    if [ $waited -ge 1800 ]; then
      echo "Timed out waiting for apt/dpkg locks after 30 min" >&2
      return 1
    fi
    echo "Another apt/dpkg process is running (probably unattended-upgrades); waiting... ($waited s)"
    sleep 15
    waited=$((waited + 15))
  done
}

# Background apt jobs (unattended-upgrades, apt-daily timers) race this script
# for the dpkg/apt locks. Mask them for the duration of setup and re-enable
# at exit so the machine stays healthy afterwards.
disable_background_apt() {
  sudo systemctl stop --quiet unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  sudo systemctl mask --quiet unattended-upgrades.service apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  wait_for_apt_locks
}

enable_background_apt() {
  sudo systemctl unmask --quiet unattended-upgrades.service apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  sudo systemctl start --quiet apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
}

disable_background_apt

echo "=== Starting setup ==="

# Set a password for the ubuntu user so Homebrew's sudo prompts work
# Generate hash and set password in one shot, bypassing PAM entirely
if ! step_done "set-password"; then
  HASHED=$(openssl passwd -6 "$EC2_USER_PASSWORD")
  sudo usermod -p "$HASHED" ubuntu
  record_step "set-password"
fi

if ! step_done "add-fish-ppa"; then
  sudo add-apt-repository ppa:fish-shell/release-4 -y < /dev/null
  record_step "add-fish-ppa"
fi

# --- Example: system updates ---
# update/upgrade/autoremove are only needed once per machine; skip on re-runs
# so repeated `just setup` calls don't redo a full apt cycle.
if ! step_done "apt-upgrade"; then
  sudo apt-get update -y < /dev/null
  wait_for_apt_locks
  sudo apt-get $CONF_OPTS upgrade -y < /dev/null
  wait_for_apt_locks
  sudo apt-get autoremove -y < /dev/null
  record_step "apt-upgrade"
fi

if ! step_done "apt-packages"; then
  wait_for_apt_locks
  sudo apt-get $CONF_OPTS install fish git nvidia-cuda-toolkit -y < /dev/null
  record_step "apt-packages"
fi

if [ "$(getent passwd ubuntu | cut -d: -f7)" != "/usr/bin/fish" ]; then
  sudo chsh -s /usr/bin/fish ubuntu
fi

# Install Homebrew *before* anything brew-dependent runs. The installer
# refuses to run as root ("Don't run this as root!"), which would otherwise
# silently fail inside the root cloud-init run and leave a broken dev shell.
if ! [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  echo "=== Installing Homebrew ==="
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u ubuntu -H env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
fi

# Delay/failure poison pill: never "complete" setup with brew missing —
# otherwise ~/.config/fish/config.fish (which calls `brew --prefix`) breaks
# every login shell until brew is installed. exit 1 aborts before the
# setup-complete flag is touched, so a re-run retries.
if ! [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  echo "ERROR: Homebrew failed to install. Aborting setup (re-run to retry)." >&2
  exit 1
fi

# Make brew available before any user config runs. fish 4 sources config
# files with parallelism, so a /etc/fish/conf.d hook alone can race (and
# lose) against the user's conf.d/config.fish — which calls `brew --prefix`
# unconditionally. /etc/environment is read by PAM for every login session,
# so PATH is set before any shell config even starts.
BREWDIR="/home/linuxbrew/.linuxbrew/bin"
export PATH="$BREWDIR:$PATH"
if ! grep -q "$BREWDIR" /etc/environment 2>/dev/null; then
  if grep -q "^PATH=" /etc/environment 2>/dev/null; then
    sudo sed -i "s|^PATH=.*|PATH=$PATH|" /etc/environment
  else
    echo "PATH=$PATH" | sudo tee -a /etc/environment > /dev/null
  fi
fi
if ! [ -f /etc/fish/conf.d/00-brew.fish ]; then
  sudo tee /etc/fish/conf.d/00-brew.fish > /dev/null <<'FISH'
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"
FISH
fi
if ! grep -q "$BREWDIR" /etc/environment 2>/dev/null; then
  echo "ERROR: Failed to add $BREWDIR to /etc/environment. Aborting setup." >&2
  exit 1
fi

# Package installs (fisher + brew formulas) are one-time work; guard the whole
# block so re-runs skip it. If anything inside fails, the marker is not
# recorded and the next run retries.
# NOTE: the EOF below must be aligned to the very left, and be the only
# content on its line, with no trailing whitespace.
if ! step_done "brew-packages"; then
fish << 'EOF'
  # Setup brew
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"

  # Install fisher
  if not type -q fisher
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher
  end
  # fisher install IlanCosman/tide@v6

  brew install neovim yazi btop fastfetch duf uv llama.cpp chezmoi zoxide eza fnm git
EOF
  record_step "brew-packages"
fi

# Clone the chezmoi source repo that setup-infra.fish uploaded to
# ~/.local/chezmoi.git, into the standard source dir, so that a later
# `chezmoi update` (git pull + apply) has something to pull from.
# Run as ubuntu: when this script is invoked as cloud-init user-data it
# executes as root, and a root-owned chezmoi source would break `chezmoi`.
if ! step_done "chezmoi-clone"; then
  if [ -d /home/ubuntu/.local/chezmoi.git ]; then
    if [ -d /home/ubuntu/.local/share/chezmoi ]; then
      echo "chezmoi source dir already exists; skipping clone"
      record_step "chezmoi-clone"
    else
      sudo -u ubuntu -H git clone /home/ubuntu/.local/chezmoi.git /home/ubuntu/.local/share/chezmoi < /dev/null
      # Apply the config immediately so the box is usable without a manual
      # `chezmoi update`. --force makes overwrite conflicts non-interactive.
      sudo -u ubuntu -H fish -c \
        'eval (/home/linuxbrew/.linuxbrew/bin/brew shellenv fish); chezmoi update --force' \
        < /dev/null
      record_step "chezmoi-clone"
    fi
  else
    echo "No ~/.local/chezmoi.git uploaded yet; not cloning chezmoi source (will clone on a later run)"
  fi
fi

# Configure the tide prompt (ships via the chezmoi config, not fisher).
# Must run as ubuntu after `chezmoi update` so the tide functions exist.
# Guarded by a marker: skipped on re-runs, retried if it failed — and if
# tide isn't visible yet (no chezmoi config applied), skip without
# recording so a later run picks it up.
if ! step_done "tide-configure"; then
  if sudo -u ubuntu -H fish -c 'type -q tide' < /dev/null 2>/dev/null; then
    echo "=== Configuring tide prompt ==="
    sudo -u ubuntu -H fish -c \
      'tide configure --auto --style=Lean --prompt_colors="True color" --show_time=No --lean_prompt_height="Two lines" --prompt_connection=Disconnected --prompt_spacing=Sparse --icons="Few icons" --transient=Yes' \
      < /dev/null
    record_step "tide-configure"
  else
    echo "tide not found (chezmoi config not applied yet?); not configuring tide (will configure on a later run)"
  fi
fi

# Delete licenses and unneeded files (ignore errors if already removed)
rm -f BUILD_FROM_SOURCE_PACKAGES_LICENCES LINUX_PACKAGES_LICENSES LINUX_PACKAGES_LIST OSSNvidiaDriver_*_license.txt 
rm -rf nvidia-acknowledgements gds-nvidia-fs

# Hand background apt jobs back (both before reboot and on repeat runs)
enable_background_apt

if [ ! -f "$SETUP_FLAG" ]; then
  printf "\nREBOOTING\n"
  echo "=== Setup complete ==="
  sudo touch "$SETUP_FLAG"
  sudo reboot
else
  echo "=== Setup already completed previously; skipping reboot ==="
fi
