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

# Example: system updates
if ! step_done "add-fish-ppa"; then
  sudo add-apt-repository ppa:fish-shell/release-4 -y < /dev/null
  record_step "add-fish-ppa"
fi

sudo apt-get update -y < /dev/null
wait_for_apt_locks
sudo apt-get $CONF_OPTS upgrade -y < /dev/null

if ! step_done "apt-packages"; then
  wait_for_apt_locks
  sudo apt-get $CONF_OPTS install fish git nvidia-cuda-toolkit -y < /dev/null
  record_step "apt-packages"
fi

if [ "$(getent passwd ubuntu | cut -d: -f7)" != "/usr/bin/fish" ]; then
  sudo chsh -s /usr/bin/fish ubuntu
fi

wait_for_apt_locks
sudo apt-get autoremove -y < /dev/null

fish << 'EOF'
  # Install brew
  if not type -q brew
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  end

  # Setup brew completions in fish shell
  set -l brew_line 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"'
  if not grep -qF -- "$brew_line" /home/ubuntu/.config/fish/config.fish 2>/dev/null
    echo >> /home/ubuntu/.config/fish/config.fish
    echo "$brew_line" >> /home/ubuntu/.config/fish/config.fish
  end
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"

  # Install fisher
  if not type -q fisher
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher
  end
  # fisher install IlanCosman/tide@v6

  brew install neovim yazi btop fastfetch duf uv llama.cpp nvtop chezmoi
EOF

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

# The above EOF needs to be aligned to the very left, and has to be the only
# line, with no trailing whitespace

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
