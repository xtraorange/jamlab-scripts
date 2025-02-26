#!/bin/bash
# -----------------------------------------------------------------------------
# Docker & Portainer Migration Script
# This script migrates all Docker containers, volumes, networks, and Portainer data
# from a source Ubuntu VM to a destination Ubuntu VM.
# -----------------------------------------------------------------------------

# Exit on any error
set -e

# ====== Section 1: Setup SSH Key-Based Authentication ======
echo ">>> Step 1: Setting up SSH key-based authentication to the destination VM..."

# Prompt for destination details
read -p "Enter the destination VM hostname or IP: " DEST_HOST
read -p "Enter the SSH username for $DEST_HOST: " DEST_USER

# Generate SSH key if not exists
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
    echo "No SSH key found. Generating a new SSH key..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa" -q
    echo "New SSH key pair generated at $HOME/.ssh/id_rsa"
fi

# Ensure known_hosts is updated to avoid prompt
ssh-keyscan -H "$DEST_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

# Try SSH connection with key (no password) to check if key is already authorized
if ssh -o BatchMode=yes -o PasswordAuthentication=no "$DEST_USER@$DEST_HOST" "echo 'SSH key auth check'" 2>/dev/null; then
    echo "SSH key already trusted on destination. Proceeding with passwordless access."
else
    echo "SSH key not installed on destination. Attempting to install it..."
    if command -v ssh-copy-id >/dev/null 2>&1; then
        # Use ssh-copy-id to copy the key&#8203;:contentReference[oaicite:3]{index=3}
        ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" "$DEST_USER@$DEST_HOST"
    else
        # If ssh-copy-id is not available, provide manual instructions
        echo "ssh-copy-id not found. Please manually add the following public key to $DEST_USER@$DEST_HOST:~/.ssh/authorized_keys"
        cat "$HOME/.ssh/id_rsa.pub"
        echo "After adding the key, press Enter to continue."
        read -s
    fi

    # Verify SSH key authentication again
    if ! ssh -o BatchMode=yes -o PasswordAuthentication=no "$DEST_USER@$DEST_HOST" "echo 'SSH connection established'" 2>/dev/null; then
        echo "ERROR: SSH key authentication failed. Please ensure the key is added to the destination VM and try again."
        exit 1
    fi
fi

echo "SSH setup complete. We can connect to $DEST_HOST as $DEST_USER without a password."

# ====== Section 2: Detect Docker Containers, Volumes, and Networks ======
echo ">>> Step 2: Gathering Docker container, volume, and network information on source..."

# Ensure Docker is installed on source
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed on the source system. Aborting."
    exit 1
fi

# Get all container IDs (including stopped)
CONTAINERS=$(docker ps -aq)
if [ -z "$CONTAINERS" ]; then
    echo "No Docker containers found on source. Exiting."
    exit 0
fi

# Get list of all Docker volumes and identify which are in use by containers
ALL_VOLUMES=$(docker volume ls -q)
# Use docker inspect to list volumes used by any container&#8203;:contentReference[oaicite:4]{index=4}
USED_VOLUMES=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' $CONTAINERS | sort -u)
# Determine unused volumes by comparing lists
UNUSED_VOLUMES=""
for VOL in $ALL_VOLUMES; do
    if ! echo "$USED_VOLUMES" | grep -qx "$VOL"; then
        UNUSED_VOLUMES="$UNUSED_VOLUMES $VOL"
    fi
done

# Get list of unique bind-mount source directories used by containers
BIND_MOUNTS=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' $CONTAINERS | sort -u)

# Get list of custom networks (user-defined networks)&#8203;:contentReference[oaicite:5]{index=5}&#8203;:contentReference[oaicite:6]{index=6}
CUSTOM_NETWORKS=$(docker network ls --filter type=custom -q)
# We'll gather network details (name, driver, subnet, gateway) for recreation on dest
NETWORK_INFO_LIST=()
for NET_ID in $CUSTOM_NETWORKS; do
    NET_NAME=$(docker network inspect -f '{{.Name}}' "$NET_ID")
    NET_DRIVER=$(docker network inspect -f '{{.Driver}}' "$NET_ID")
    # Get subnet and gateway if any (for bridge networks, etc.)
    IPAM_SUBNET=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET_ID")
    IPAM_GATEWAY=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$NET_ID")
    NETWORK_INFO_LIST+=("$NET_NAME::$NET_DRIVER::$IPAM_SUBNET::$IPAM_GATEWAY")
    echo "Found custom Docker network: $NET_NAME (driver: $NET_DRIVER, subnet: ${IPAM_SUBNET:-"default"}, gateway: ${IPAM_GATEWAY:-"default"})"
done

# Identify Portainer containers (server and agent, if any)
PORTAINER_SERVER_CNT=$(docker ps -a --filter "ancestor=portainer/portainer" --filter "ancestor=portainer/portainer-ce" --filter "ancestor=portainer/portainer-ee" --format "{{.Names}}" | head -n1)
PORTAINER_AGENT_CNT=$(docker ps -a --filter "ancestor=portainer/agent" --format "{{.Names}}" | head -n1)

if [ -n "$PORTAINER_SERVER_CNT" ]; then
    echo "Detected Portainer server container: $PORTAINER_SERVER_CNT"
else
    echo "No Portainer server container detected."
fi
if [ -n "$PORTAINER_AGENT_CNT" ]; then
    echo "Detected Portainer agent container: $PORTAINER_AGENT_CNT"
fi

# If Portainer server is running, note its data volume or bind mount (usually at /data)
if [ -n "$PORTAINER_SERVER_CNT" ]; then
    PORTAINER_DATA_MOUNT=$(docker inspect -f '{{range .Mounts}}{{if or (eq .Destination "/data") (eq .Destination "/portainer")}}{{.Source}}{{end}}{{end}}' "$PORTAINER_SERVER_CNT")
    if [ -n "$PORTAINER_DATA_MOUNT" ]; then
        echo "Portainer data is stored in: $PORTAINER_DATA_MOUNT"
    fi
fi

# ====== Section 3: Stop Containers and Prepare for Data Transfer ======
echo ">>> Step 3: Stopping running containers on source to prepare for data transfer..."
docker stop $CONTAINERS 2>/dev/null || true
# (If any container fails to stop or is already stopped, it's fine. We're ensuring no changes during copy.)

# Determine Docker data root directory on source (usually /var/lib/docker)&#8203;:contentReference[oaicite:7]{index=7}
SRC_DOCKER_DIR=$(docker info -f '{{.DockerRootDir}}')
echo "Source Docker data directory: $SRC_DOCKER_DIR"

# Also get Docker data directory on destination (we assume it should be the same path for identical config)
DEST_DOCKER_DIR="$SRC_DOCKER_DIR"

# ====== Section 4: Install Docker on Destination (if needed) ======
echo ">>> Step 4: Ensuring Docker is installed on destination VM..."
if ! ssh "$DEST_USER@$DEST_HOST" "command -v docker >/dev/null 2>&1"; then
    echo "Docker not found on destination. Installing Docker..."
    ssh "$DEST_USER@$DEST_HOST" "sudo apt-get update -qq && sudo apt-get install -y -qq docker.io"
    # After install, add current user to docker group for convenience (optional)
    ssh "$DEST_USER@$DEST_HOST" "sudo usermod -aG docker $DEST_USER" || true
else
    echo "Docker is already installed on destination."
fi

# If a Docker daemon configuration file exists on source, transfer it to destination for identical setup
if [ -f "/etc/docker/daemon.json" ]; then
    echo "Transferring Docker daemon configuration to destination..."
    scp "/etc/docker/daemon.json" "$DEST_USER@$DEST_HOST:/tmp/daemon.json"
    ssh "$DEST_USER@$DEST_HOST" "sudo mkdir -p /etc/docker && sudo mv /tmp/daemon.json /etc/docker/daemon.json"
fi

# Stop Docker on destination before data transfer (to ensure no conflicts and data consistency)
echo "Stopping Docker service on destination..."
ssh "$DEST_USER@$DEST_HOST" "sudo systemctl stop docker"

# Ensure the Docker data directory exists on destination
ssh "$DEST_USER@$DEST_HOST" "sudo mkdir -p $DEST_DOCKER_DIR"

# ====== Section 5: Transfer Docker Data via rsync ======
echo ">>> Step 5: Transferring Docker data from source to destination using rsync..."
# Build rsync exclude parameters for unused volumes
RSYNC_EXCLUDES=""
for VOL in $UNUSED_VOLUMES; do
    RSYNC_EXCLUDES="$RSYNC_EXCLUDES --exclude=volumes/$VOL/"
done

# Use rsync to copy everything from Docker data directory, excluding unused volumes&#8203;:contentReference[oaicite:8]{index=8}.
# -a : archive mode (preserves permissions, ownership, timestamps)
# -x : don't cross filesystem boundaries (stay in Docker directory)
# -H : preserve hard links
# -v : verbose output to show progress
echo "Starting data transfer... This may take a while for large volumes/images."
rsync -ahxH $RSYNC_EXCLUDES -e "ssh" "$SRC_DOCKER_DIR/" "$DEST_USER@$DEST_HOST:$DEST_DOCKER_DIR/"

# After transfer, set correct ownership on destination Docker data (in case we weren't root during rsync)
echo "Setting proper ownership on destination Docker files..."
ssh "$DEST_USER@$DEST_HOST" "sudo chown -R root:root $DEST_DOCKER_DIR"

echo "Docker data transfer complete."

# ====== Section 6: Recreate Custom Networks on Destination ======
if [ "${#NETWORK_INFO_LIST[@]}" -gt 0 ]; then
    echo ">>> Step 6: Recreating custom Docker networks on destination..."
    for NET_INFO in "${NETWORK_INFO_LIST[@]}"; do
        IFS="::" read -r NET_NAME NET_DRIVER NET_SUBNET NET_GW <<< "$NET_INFO"
        # Skip if network name is empty (just in case)
        [ -z "$NET_NAME" ] && continue
        # Construct network create command
        CREATE_CMD="docker network create -d $NET_DRIVER"
        # Include subnet and gateway if available
        if [ -n "$NET_SUBNET" ]; then
            CREATE_CMD="$CREATE_CMD --subnet=$NET_SUBNET"
            [ -n "$NET_GW" ] && CREATE_CMD="$CREATE_CMD --gateway=$NET_GW"
        fi
        CREATE_CMD="$CREATE_CMD $NET_NAME"
        # Execute on destination
        ssh "$DEST_USER@$DEST_HOST" "sudo $CREATE_CMD" || true
        echo "Recreated network '$NET_NAME' on destination."
    done
fi

# ====== Section 7: Restore Portainer on Destination ======
if [ -n "$PORTAINER_SERVER_CNT" ]; then
    echo ">>> Step 7: Restoring Portainer on destination..."
    # Ensure Portainer data volume or directory is in place (it was included in rsync if it was a named volume or bind mount).
    # Start Portainer container on destination using the same image/tag as source.
    PORTAINER_IMG=$(docker inspect -f '{{.Config.Image}}' "$PORTAINER_SERVER_CNT")
    # Open Portainer ports (assuming default ports were used on source, adjust if needed)
    PORTS_ARGS="-p 9000:9000"
    # If the old Portainer used an agent and was Edge, there might be port 8000 for Edge agent. Check if port 8000 was exposed:
    if docker inspect -f '{{range.NetworkSettings.Ports}}{{ if eq .PublicPort 8000 }}yes{{ end }}{{end}}' "$PORTAINER_SERVER_CNT" | grep -q yes; then
       PORTS_ARGS="$PORTS_ARGS -p 8000:8000"
    fi
    # If Portainer was bound to the Docker socket, include that mount
    SOCKET_ARG=""
    if docker inspect -f '{{range .Mounts}}{{if eq .Source "/var/run/docker.sock"}}yes{{end}}{{end}}' "$PORTAINER_SERVER_CNT" | grep -q yes; then
       SOCKET_ARG="-v /var/run/docker.sock:/var/run/docker.sock"
    fi
    # Run Portainer container on destination
    ssh "$DEST_USER@$DEST_HOST" "sudo docker run -d --name $PORTAINER_SERVER_CNT \
        $PORTS_ARGS $SOCKET_ARG \
        -v portainer_data:/data \
        $PORTAINER_IMG"
    echo "Portainer server container started on destination with image $PORTAINER_IMG."
fi

if [ -n "$PORTAINER_AGENT_CNT" ]; then
    echo "Starting Portainer agent on destination..."
    PORTAINER_AGENT_IMG=$(docker inspect -f '{{.Config.Image}}' "$PORTAINER_AGENT_CNT")
    # Re-run agent (the agent typically needs to connect back to Portainer server; ensure the agent command/Env if any are carried over)
    # We retrieve the original command and environment if possible
    AGENT_CMD=$(docker inspect -f '{{.Config.Cmd}}' "$PORTAINER_AGENT_CNT")
    AGENT_ENV=$(docker inspect -f '{{range .Config.Env}}{{printf "%q " .}}{{end}}' "$PORTAINER_AGENT_CNT")
    ssh "$DEST_USER@$DEST_HOST" "sudo docker run -d --name $PORTAINER_AGENT_CNT $AGENT_ENV $PORTAINER_AGENT_IMG $AGENT_CMD"
    echo "Portainer agent container started on destination."
fi

# ====== Section 8: Recreate Bind-Mounted Directories on Destination ======
echo ">>> Step 8: Ensuring bind-mount directories exist on destination and have correct data..."
for DIR in $BIND_MOUNTS; do
    # Skip Docker socket and other system paths that are not actual data directories
    if [[ "$DIR" == "/var/run/"* ]] || [[ "$DIR" == "/proc/"* ]] || [[ "$DIR" == "/dev/"* ]] || [[ "$DIR" == "/sys/"* ]] || [[ "$DIR" == "/etc/localtime" ]] || [[ "$DIR" == "/etc/timezone" ]]; then
        continue  # no need to transfer these
    fi
    echo "Recreating directory $DIR on destination..."
    ssh "$DEST_USER@$DEST_HOST" "sudo mkdir -p $DIR"
    # Rsync the contents of the bind-mount directory to destination (if any content to transfer)
    if [ -d "$DIR" ]; then
        rsync -ahxH -e "ssh" "$DIR/" "$DEST_USER@$DEST_HOST:$DIR/" || true
        ssh "$DEST_USER@$DEST_HOST" "sudo chown -R \$(stat -c '%u:%g' $DIR) $DIR"
    fi
done

# ====== Section 9: Start Docker and Containers on Destination ======
echo ">>> Step 9: Starting Docker service and all containers on destination..."
ssh "$DEST_USER@$DEST_HOST" "sudo systemctl start docker"

# Give Docker a few seconds to initialize
sleep 5

# Start all containers on destination&#8203;:contentReference[oaicite:9]{index=9}
ssh "$DEST_USER@$DEST_HOST" "sudo docker start \$(sudo docker ps -a -q)"

echo "All containers have been started on the destination. Verifying status..."
ssh "$DEST_USER@$DEST_HOST" "sudo docker ps -a"

echo ">>> Migration complete! All Docker containers, volumes, and Portainer data should now be migrated to $DEST_HOST."

# End of script
