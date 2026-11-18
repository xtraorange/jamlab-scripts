#!/usr/bin/env bash
# Build the Proxmox golden image (a cloud-init VM template) from the official Ubuntu cloud image.
# One command does everything: run it as root on the Proxmox node that will host the VMs.
#
#   curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/make-golden-image.sh | bash
#
# What it does, so you do not have to:
#   - downloads the public keys for the "ansible" account from keys/ansible.pub in this repo and shows them
#   - installs libguestfs-tools if it is missing
#   - picks the storage for VM disks, the VM ID (first free from 9000) and the bridge
#   - downloads the Ubuntu cloud image, verifies its checksum, installs qemu-guest-agent into it
#   - creates the VM, sets up cloud-init (user "ansible" with those keys, passwordless sudo, key-only),
#     converts it to a template and protects it against deletion
#   - is safe to run again: if the template already exists on this node it says so and stops
#
# The image holds only what Ansible needs to reach a new VM. Users, updates, SSH hardening,
# node exporter and Docker are applied by Ansible afterwards.
#
# Optional settings (environment variables, all prefixed GOLDEN_; defaults in brackets):
#   GOLDEN_KEYS_URL [keys/<account>.pub in this repo]   URL of a file holding the account's public keys
#   GOLDEN_KEYS_FILE [none]   use a local file of public keys instead of downloading (offline rebuilds)
#   GOLDEN_NAME [ubuntu-golden]  GOLDEN_RELEASE [noble]  GOLDEN_BRIDGE [vmbr0]  GOLDEN_CI_USER [ansible]
#   GOLDEN_CORES [2]  GOLDEN_MEMORY [2048]  GOLDEN_DISK_SIZE [20G]
#   GOLDEN_STORAGE [auto]   GOLDEN_VMID [auto]
#
# Example with a setting:   curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/make-golden-image.sh | GOLDEN_STORAGE=local-zfs bash
# Templates live on one node's storage, so run this once on each node that will host new VMs
# (unless the storage is shared).
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }
vmid_taken() { compgen -G "${PVE_NODES}/*/qemu-server/$1.conf" >/dev/null; }

# Everything runs inside main() with stdin closed: when this script is piped into bash
# (curl ... | bash), a command that reads stdin could otherwise swallow the rest of the script.
main() {
NAME="${GOLDEN_NAME:-ubuntu-golden}"
RELEASE="${GOLDEN_RELEASE:-noble}"
BRIDGE="${GOLDEN_BRIDGE:-vmbr0}"
CORES="${GOLDEN_CORES:-2}"
MEMORY="${GOLDEN_MEMORY:-2048}"
DISK_SIZE="${GOLDEN_DISK_SIZE:-20G}"
CI_USER="${GOLDEN_CI_USER:-ansible}"
KEYS_URL="${GOLDEN_KEYS_URL:-https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/keys/${CI_USER}.pub}"
KEYS_FILE="${GOLDEN_KEYS_FILE:-}"
STORAGE="${GOLDEN_STORAGE:-}"
VMID="${GOLDEN_VMID:-}"
PVE_NODES="${PVE_NODES:-/etc/pve/nodes}"   # only changed by tests
NODE="${GOLDEN_NODE:-$(hostname)}"          # GOLDEN_NODE is only for tests

IMAGE_FILE="${RELEASE}-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/${RELEASE}/current/${IMAGE_FILE}"
SUMS_URL="https://cloud-images.ubuntu.com/${RELEASE}/current/SHA256SUMS"

# ---- checks --------------------------------------------------------------------------------
if [ "${ALLOW_NONROOT:-0}" != "1" ]; then   # ALLOW_NONROOT is only for tests
  [ "$(id -u)" -eq 0 ] || die "run as root on a Proxmox node"
fi
for c in qm pvesm curl; do command -v "$c" >/dev/null || die "$c not found: this must run on a Proxmox node"; done

# Already built on this node? Then there is nothing to do.
for conf in "${PVE_NODES}/${NODE}"/qemu-server/*.conf; do
  [ -e "$conf" ] || continue
  if grep -qx "name: ${NAME}" "$conf" && grep -qx 'template: 1' "$conf"; then
    echo "Golden image '${NAME}' already exists on ${NODE} (VM $(basename "$conf" .conf)). Nothing to do."
    exit 0
  fi
done

# VM ID: first free from 9000 unless one was given.
if [ -z "$VMID" ]; then
  VMID=9000
  while vmid_taken "$VMID"; do
    VMID=$((VMID + 1))
    [ "$VMID" -lt 9100 ] || die "no free VM ID between 9000 and 9099; set GOLDEN_VMID"
  done
elif vmid_taken "$VMID"; then
  die "VM ID ${VMID} already exists in the cluster; pick another with GOLDEN_VMID=..."
fi

# Storage: any active storage that can hold VM disks; prefer local-lvm.
if [ -z "$STORAGE" ]; then
  mapfile -t CANDIDATES < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  [ "${#CANDIDATES[@]}" -gt 0 ] || die "no active storage can hold VM disks; set GOLDEN_STORAGE"
  STORAGE="${CANDIDATES[0]}"
  for c in "${CANDIDATES[@]}"; do [ "$c" = "local-lvm" ] && STORAGE="$c"; done
  info "Using storage '${STORAGE}' (set GOLDEN_STORAGE to change)"
else
  # (awk instead of grep -q: with pipefail, grep -q can end the pipe early and fail a good match)
  pvesm status | awk -v s="$STORAGE" 'NR>1 && $1==s {found=1} END {exit !found}' \
    || die "storage '$STORAGE' not found (pvesm status)"
fi

WORKDIR="$(mktemp -d /var/tmp/golden-image.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

# ---- SSH keys from GitHub ------------------------------------------------------------------
if [ -n "$KEYS_FILE" ]; then
  info "Using SSH public keys from ${KEYS_FILE}"
  cp "$KEYS_FILE" keys.pub || die "cannot read ${KEYS_FILE}"
else
  info "Fetching SSH public keys from ${KEYS_URL}"
  curl -fsSL -o keys.pub "$KEYS_URL" || die "could not download keys from ${KEYS_URL} (is the key file in the repo?)"
fi
grep -Eq '^(ssh-|ecdsa-|sk-)' keys.pub || die "no SSH public keys found in the key file"
echo "These keys will be able to log in as '${CI_USER}' (make sure Ansible's key is one of them):"
ssh-keygen -l -f keys.pub | sed 's/^/    /'

# ---- tools ---------------------------------------------------------------------------------
if ! command -v virt-customize >/dev/null; then
  info "Installing libguestfs-tools (provides virt-customize) ..."
  # apt-get update can fail on Proxmox without a subscription (enterprise repo); that is not fatal here.
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libguestfs-tools \
    || die "could not install libguestfs-tools; install it by hand (apt install libguestfs-tools) and re-run"
fi
export LIBGUESTFS_BACKEND=direct

# ---- download and verify -------------------------------------------------------------------
info "Downloading ${IMAGE_URL}"
curl -fsSL -o "$IMAGE_FILE" "$IMAGE_URL"
curl -fsSL -o SHA256SUMS "$SUMS_URL"
grep " \*\?${IMAGE_FILE}\$" SHA256SUMS | sha256sum -c - || die "checksum of ${IMAGE_FILE} did not match"

# ---- customise the disk image --------------------------------------------------------------
info "Installing qemu-guest-agent into the image"
virt-customize -a "$IMAGE_FILE" --install qemu-guest-agent --run-command 'systemctl enable qemu-guest-agent'
qemu-img resize "$IMAGE_FILE" "$DISK_SIZE"

# ---- create the VM -------------------------------------------------------------------------
info "Creating VM ${VMID} (${NAME}) on storage ${STORAGE}"
qm create "$VMID" --name "$NAME" --ostype l26 \
  --cores "$CORES" --memory "$MEMORY" --cpu x86-64-v2-AES \
  --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-pci \
  --agent enabled=1 --serial0 socket --vga serial0

# "qm disk import" is the current name; older Proxmox versions call it "qm importdisk".
qm disk import "$VMID" "$IMAGE_FILE" "$STORAGE" >/dev/null 2>&1 \
  || qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" >/dev/null
DISK_REF="$(qm config "$VMID" | awk -F': ' '/^unused0:/ {print $2}')"
[ -n "$DISK_REF" ] || die "disk import did not produce unused0; check: qm config ${VMID}"
qm set "$VMID" --scsi0 "$DISK_REF" --boot order=scsi0

# ---- cloud-init ----------------------------------------------------------------------------
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --ciuser "$CI_USER" --sshkeys "$WORKDIR/keys.pub" --ipconfig0 ip=dhcp

# ---- finish --------------------------------------------------------------------------------
qm template "$VMID"
# Protection blocks deleting the VM or its disks until you clear it (qm set <id> --protection 0).
qm set "$VMID" --protection 1

cat <<EOF

Golden image ready: VM ${VMID} (${NAME}) on ${NODE}, protected against deletion.

Make a new VM from it with the clone script, for example:
  curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/clone-vm.sh | bash -s -- docker-dns --vlan 20 --ip 10.10.20.5/24 --gw 10.10.20.1 --start

Then add the host to ansible/inventory/all_servers.ini and run the Ansible playbooks.
EOF
}

main "$@" </dev/null
