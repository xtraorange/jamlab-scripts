#!/bin/bash
set -eux

if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root. Please use 'sudo' or run as root user."
    exit 1
fi

# Define variables for clarity
TELEPORT_PROXY="${TELEPORT_PROXY:-}"
TELEPORT_TOKEN="${TELEPORT_TOKEN:-}"

if [[ -z "$TELEPORT_PROXY" ]]; then
    echo "❌ Error: No Teleport Proxy IP provided. Set TELEPORT_PROXY=<IP> before running."
    exit 1
fi

if [[ -z "$TELEPORT_TOKEN" ]]; then
    echo "❌ Error: No token provided. Set TELEPORT_TOKEN=<TOKEN> before running."
    exit 1
fi

AUTH_SERVER="${TELEPORT_PROXY}:3025"
NODE_NAME=$(hostname)
CONFIG_PATH="/etc/teleport.yaml"

echo "🔹 Installing Teleport..."
apt update && apt install -y teleport

echo "🔹 Configuring Teleport..."
mkdir -p /etc/teleport
cat > "$CONFIG_PATH" <<EOF
teleport:
  nodename: "$NODE_NAME"
  data_dir: "/var/lib/teleport"
  log:
    output: stderr
    severity: INFO
    format:
      output: text
  auth_token: "$TELEPORT_TOKEN"
  auth_servers:
    - "$AUTH_SERVER"

auth_service:
  enabled: "no"

ssh_service:
  enabled: "yes"
  pam:
    enabled: true 

proxy_service:
  enabled: "no"
EOF

echo "🔹 Setting correct permissions for Teleport..."
chmod 600 "$CONFIG_PATH"
chown root:root "$CONFIG_PATH"

echo "🔹 Updating Teleport service to use --insecure..."
sed -i 's|ExecStart=.*|ExecStart=/usr/local/bin/teleport start --config=/etc/teleport.yaml --insecure|' /lib/systemd/system/teleport.service

echo "🔹 Reloading and restarting Teleport..."
systemctl daemon-reload
systemctl enable --now teleport

echo "✅ Teleport installation complete. The node should now be visible in the cluster."
