#!/bin/bash
set -eux

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root. Please use 'sudo' or run as root user."
    exit 1
fi

# Check if the Teleport Proxy IP is provided
if [[ -z "${1:-}" ]]; then
    echo "❌ Error: No Teleport Proxy IP provided. Usage: sudo bash install-node.sh <TELEPORT_PROXY_IP>"
    exit 1
fi

TELEPORT_PROXY="$1"
AUTH_SERVER="${TELEPORT_PROXY}:3025"
NODE_NAME=$(hostname)
CONFIG_PATH="/etc/teleport/teleport.yaml"

# Fetch the join token dynamically from Teleport
TELEPORT_TOKEN=$(curl -s --insecure "https://${TELEPORT_PROXY}:3080/api/v1/join-token" | jq -r '.token')

if [[ -z "$TELEPORT_TOKEN" || "$TELEPORT_TOKEN" == "null" ]]; then
    echo "❌ Error: Failed to fetch join token. Make sure the API is accessible."
    exit 1
fi

echo "🔹 Installing Teleport..."

# Install Teleport (Ubuntu/Debian)
apt update && apt install -y teleport

echo "🔹 Configuring Teleport..."

# Create the Teleport config
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
  insecure_skip_verify: true
auth_service:
  enabled: "no"
ssh_service:
  enabled: "yes"
proxy_service:
  enabled: "no"
EOF

echo "🔹 Starting Teleport..."
teleport start --config=$CONFIG_PATH &

echo "✅ Teleport installation complete. The node should now be visible in the cluster."
