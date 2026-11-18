#!/usr/bin/env bash
# Clone the golden image into a new VM, with its name, VLAN and IP set through cloud-init.
# Run as root on the Proxmox node that holds the template (it finds the template by name itself).
#
#   curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/clone-vm.sh | bash -s -- NAME --vlan N --ip CIDR --gw GATEWAY [options]
#
# Required:
#   NAME            VM name; cloud-init also uses it as the hostname (match the Ansible inventory name)
#   --vlan N        VLAN tag for the NIC (use --vlan 0 for untagged)
#   --ip CIDR       static address such as 10.10.20.5/24, or "dhcp"
#   --gw ADDRESS    default gateway (not needed with --ip dhcp)
# Optional:
#   --id N          VM ID (default: next free ID in the cluster)
#   --template N    template VM ID (default: the template named ubuntu-golden on this node)
#   --bridge NAME   bridge (default: vmbr0)
#   --cores N       CPU cores (default: from the template)
#   --memory MB     memory (default: from the template)
#   --disk-add SIZE grow the disk by this much, for example 20G
#   --dns ADDRESS   DNS server for the VM (default: inherit from the Proxmox host)
#   --search DOMAIN DNS search domain
#   --start         start the VM when done
#
# Example:
#   curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/clone-vm.sh | bash -s -- docker-dns --vlan 20 --ip 10.10.20.5/24 --gw 10.10.20.1 --dns 1.1.1.1 --start
#
# Do not point a DNS server's own VM at itself: give the DNS VM a public resolver with --dns.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Clone the golden image into a new VM, with its name, VLAN and IP set through cloud-init.
Run as root on the Proxmox node that holds the template (it finds the template by name itself).

  curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/clone-vm.sh | bash -s -- NAME --vlan N --ip CIDR --gw GATEWAY [options]

Required:
  NAME            VM name; also the hostname (match the Ansible inventory name)
  --vlan N        VLAN tag for the NIC (0 = untagged)
  --ip CIDR       static address such as 10.10.20.5/24, or "dhcp"
  --gw ADDRESS    default gateway (not needed with --ip dhcp)
Optional:
  --id N          VM ID (default: next free ID in the cluster)
  --template N    template VM ID (default: the template named ubuntu-golden on this node)
  --bridge NAME   bridge (default: vmbr0)
  --cores N       CPU cores         --memory MB   memory
  --disk-add SIZE grow the disk by this much, for example 20G
  --dns ADDRESS   DNS server for the VM (default: inherit from the Proxmox host)
  --search DOMAIN DNS search domain
  --start         start the VM when done

Do not point a DNS server's own VM at itself: give the DNS VM a public resolver with --dns.
USAGE
  exit 1
}

# Everything runs inside main() with stdin closed, so that piping this script into bash
# (curl ... | bash) cannot have a command swallow the rest of the script.
main() {
PVE_NODES="${PVE_NODES:-/etc/pve/nodes}"   # only changed by tests
NODE="${GOLDEN_NODE:-$(hostname)}"          # GOLDEN_NODE is only for tests
TEMPLATE_NAME="${GOLDEN_NAME:-ubuntu-golden}"

if [ "${ALLOW_NONROOT:-0}" != "1" ]; then   # ALLOW_NONROOT is only for tests
  [ "$(id -u)" -eq 0 ] || die "run as root on a Proxmox node"
fi
command -v qm >/dev/null || die "qm not found: this must run on a Proxmox node"

case "${1:-}" in ""|-h|--help) usage ;; esac
NAME="$1"; shift
TEMPLATE=""; BRIDGE=vmbr0; VLAN=""; IP=""; GW=""; VMID=""; CORES=""; MEMORY=""
DISK_ADD=""; DNS=""; SEARCH=""; START=0

while [ $# -gt 0 ]; do
  case "$1" in
    --vlan) VLAN="${2:?--vlan needs a value}"; shift 2 ;;
    --ip) IP="${2:?--ip needs a value}"; shift 2 ;;
    --gw) GW="${2:?--gw needs a value}"; shift 2 ;;
    --id) VMID="${2:?--id needs a value}"; shift 2 ;;
    --template) TEMPLATE="${2:?--template needs a value}"; shift 2 ;;
    --bridge) BRIDGE="${2:?--bridge needs a value}"; shift 2 ;;
    --cores) CORES="${2:?--cores needs a value}"; shift 2 ;;
    --memory) MEMORY="${2:?--memory needs a value}"; shift 2 ;;
    --disk-add) DISK_ADD="${2:?--disk-add needs a value}"; shift 2 ;;
    --dns) DNS="${2:?--dns needs a value}"; shift 2 ;;
    --search) SEARCH="${2:?--search needs a value}"; shift 2 ;;
    --start) START=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[[ "$NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || die "NAME must be a valid hostname (letters, digits, hyphens)"
[ -n "$VLAN" ] || die "--vlan is required (use 0 for untagged)"
[ -n "$IP" ] || die "--ip is required (CIDR or dhcp)"
if [ "$IP" != "dhcp" ]; then
  [[ "$IP" == */* ]] || die "--ip must include the prefix length, for example 10.10.20.5/24"
  [ -n "$GW" ] || die "--gw is required with a static IP"
fi

# Find the template by name on this node unless an ID was given.
if [ -z "$TEMPLATE" ]; then
  for conf in "${PVE_NODES}/${NODE}"/qemu-server/*.conf; do
    [ -e "$conf" ] || continue
    if grep -qx "name: ${TEMPLATE_NAME}" "$conf" && grep -qx 'template: 1' "$conf"; then
      TEMPLATE="$(basename "$conf" .conf)"; break
    fi
  done
  [ -n "$TEMPLATE" ] || die "no template named '${TEMPLATE_NAME}' on ${NODE}. Build it first: curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/make-golden-image.sh | bash"
fi
compgen -G "${PVE_NODES}/*/qemu-server/${TEMPLATE}.conf" >/dev/null || die "template ${TEMPLATE} not found"
grep -q '^template: 1' "${PVE_NODES}"/*/qemu-server/"${TEMPLATE}".conf || die "VM ${TEMPLATE} is not a template"

[ -n "$VMID" ] || VMID="$(pvesh get /cluster/nextid)"
if compgen -G "${PVE_NODES}/*/qemu-server/${VMID}.conf" >/dev/null; then
  die "VM ID ${VMID} already exists"
fi

echo ">> Cloning template ${TEMPLATE} to VM ${VMID} (${NAME})"
qm clone "$TEMPLATE" "$VMID" --name "$NAME" --full 1

NET="virtio,bridge=${BRIDGE}"
[ "$VLAN" = "0" ] || NET="${NET},tag=${VLAN}"
qm set "$VMID" --net0 "$NET" --onboot 1

if [ "$IP" = "dhcp" ]; then
  qm set "$VMID" --ipconfig0 ip=dhcp
else
  qm set "$VMID" --ipconfig0 "ip=${IP},gw=${GW}"
fi
[ -z "$DNS" ] || qm set "$VMID" --nameserver "$DNS"
[ -z "$SEARCH" ] || qm set "$VMID" --searchdomain "$SEARCH"
[ -z "$CORES" ] || qm set "$VMID" --cores "$CORES"
[ -z "$MEMORY" ] || qm set "$VMID" --memory "$MEMORY"
[ -z "$DISK_ADD" ] || qm resize "$VMID" scsi0 "+${DISK_ADD}"
[ "$START" -eq 0 ] || qm start "$VMID"

ADDR="${IP%%/*}"
echo
echo "VM ${VMID} (${NAME}) created. IP: ${IP}${GW:+, gateway ${GW}}, VLAN ${VLAN}."
if [ "$START" -eq 1 ]; then echo "Started. It configures itself on first boot; give it a minute, then:"
else echo "Start it with: qm start ${VMID}   then:"; fi
echo "  1. Add it to ansible/inventory/all_servers.ini, for example:  ${NAME} ansible_host=${ADDR}"
echo "  2. Check you can log in:  ssh ansible@${ADDR}"
echo "  3. Run the Ansible playbooks (users, baseline; coolify_node.yml for a Coolify node)."
}

main "$@" </dev/null
