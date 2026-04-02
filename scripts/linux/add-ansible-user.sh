#!/usr/bin/env bash
# One-line install:
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/linux/add-ansible-user.sh)"

set -euo pipefail

ANSIBLE_USER="ansible"
ANSIBLE_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIITguQZKDYKEiLOjrDUzmd86VkUXqLhypaAjp+h5g607"
SUDOERS_FILE="/etc/sudoers.d/90-ansible"

if [ "${EUID}" -ne 0 ]; then
    echo "Please run this script as root."
    exit 1
fi

echo "==> Detecting environment..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Detected: ${PRETTY_NAME:-unknown}"
else
    echo "Could not detect OS from /etc/os-release, continuing anyway."
fi

if ! command -v sudo >/dev/null 2>&1; then
    echo "==> sudo not found, installing..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y sudo
    else
        echo "Error: sudo is not installed and no supported package manager was found."
        exit 1
    fi
fi

if id "$ANSIBLE_USER" >/dev/null 2>&1; then
    echo "==> User '$ANSIBLE_USER' already exists."
else
    echo "==> Creating user '$ANSIBLE_USER'..."
    useradd -m -s /bin/bash "$ANSIBLE_USER"
fi

HOME_DIR="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6)"
if [ -z "$HOME_DIR" ]; then
    echo "Error: could not determine home directory for '$ANSIBLE_USER'."
    exit 1
fi

SSH_DIR="$HOME_DIR/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

echo "==> Setting up SSH directory..."
install -d -m 700 -o "$ANSIBLE_USER" -g "$ANSIBLE_USER" "$SSH_DIR"

touch "$AUTHORIZED_KEYS"
chown "$ANSIBLE_USER:$ANSIBLE_USER" "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

if grep -qxF "$ANSIBLE_KEY" "$AUTHORIZED_KEYS"; then
    echo "==> SSH key already present."
else
    echo "==> Adding SSH key..."
    echo "$ANSIBLE_KEY" >> "$AUTHORIZED_KEYS"
fi

echo "==> Configuring passwordless sudo..."
mkdir -p /etc/sudoers.d
cat > "$SUDOERS_FILE" <<EOF
$ANSIBLE_USER ALL=(ALL:ALL) NOPASSWD:ALL
EOF
chmod 440 "$SUDOERS_FILE"

if command -v visudo >/dev/null 2>&1; then
    echo "==> Validating sudoers configuration..."
    visudo -cf "$SUDOERS_FILE"
fi

echo "==> Done."
echo "User '$ANSIBLE_USER' is ready for Ansible access."