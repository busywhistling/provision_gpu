#!/bin/bash
set -e
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
  sudo add-apt-repository ppa:fish-shell/release-4 -y
  record_step "add-fish-ppa"
fi

sudo apt update -y
sudo apt upgrade -y

if ! step_done "apt-packages"; then
  sudo apt install fish nvidia-cuda-toolkit -y
  record_step "apt-packages"
fi

if [ "$(getent passwd ubuntu | cut -d: -f7)" != "/usr/bin/fish" ]; then
  sudo chsh -s /usr/bin/fish ubuntu
fi

sudo apt autoremove -y

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

  brew install neovim yazi btop fastfetch duf uv
EOF

# The above EOF needs to be aligned to the very left, and has to be the only
# line, with no trailing whitespace

# Delete licenses and unneeded files (ignore errors if already removed)
rm -f BUILD_FROM_SOURCE_PACKAGES_LICENCES LINUX_PACKAGES_LICENSES LINUX_PACKAGES_LIST OSSNvidiaDriver_v595.71.05_license.txt
rm -rf nvidia-acknowledgements gds-nvidia-fs

if [ ! -f "$SETUP_FLAG" ]; then
  printf "\nREBOOTING\n"
  echo "=== Setup complete ==="
  sudo touch "$SETUP_FLAG"
  sudo reboot
else
  echo "=== Setup already completed previously; skipping reboot ==="
fi
