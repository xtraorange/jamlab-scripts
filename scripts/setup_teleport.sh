#!/bin/bash
set -eux

if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root. Please use 'sudo' or run as root user."
    exit 1
fi

if [[ -z "${1:-}" ]]; then
    echo "❌ Error: No Teleport Proxy IP provided. Usage: sudo bash setup_teleport.sh <TELEPORT_PROXY_IP> <TOKEN>"
    exit 1
fi

if [[ -z "${2:-}" ]]; then
    echo "❌ Error: No token provided. Run 'tctl nodes add --roles=node' to generate one."
    exit 1
fi

TELEPORT_PROXY="$1"
AUTH_SERVER="${TELEPORT_PROXY}:3025"
NODE_NAME=$(hostname)
CONFIG_PATH="/etc/teleport/teleport.yaml"
TELEPORT_TOKEN="$2"

echo "🔹 Installing Teleport..."
apt update && apt install -y teleport

echo "🔹 Configuring Teleport..."
mkdir -p $(dirname $CONFIG_PATH)
cat > $CONFIG_PATH <<EOF
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
    enabled: true  # Enable PAM authentication so Teleport can create users dynamically
  allow_user_creation: true  # Allow Teleport to create users dynamically

proxy_service:
  enabled: "no"
EOF

echo "🔹 Starting Teleport..."
teleport start --config=$CONFIG_PATH --insecure &

echo "✅ Teleport installation complete. The node should now be visible in the cluster."
