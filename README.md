# JamLab Scripts
 A collection of public facing scripts I use.

## Proxmox golden image and new VMs

Run these as root on a Proxmox node. The first builds the golden image (a cloud-init VM template with the
Ubuntu cloud image, `qemu-guest-agent`, and an `ansible` account that accepts the keys in
[`keys/ansible.pub`](keys/ansible.pub)). It finds the storage and a free VM ID itself and is safe to run again.
Run it once per node that will host VMs (unless your storage is shared).

```bash
curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/make-golden-image.sh | bash
```

The second clones the template into a new VM with its name and VLAN set through cloud-init. The address comes from DHCP (add `--ip CIDR --gw ADDRESS` only for a static one):

```bash
curl -fsSL https://raw.githubusercontent.com/xtraorange/jamlab-scripts/main/scripts/proxmox/clone-vm.sh | bash -s -- docker-dns --id 104 --vlan 4 --dns 1.1.1.1
```

Run either with `--help` (clone) or read the header of the script (build) for the options. After cloning, add
the host to the Ansible inventory and run the playbooks (users, baseline, and `coolify_node.yml` for a Coolify
node): the image holds only what Ansible needs to reach the VM.

## Other scripts

- `scripts/linux/add-ansible-user.sh` - add the `ansible` user with its key and passwordless sudo to an existing machine.
- `scripts/migrate_docker.sh` - older Docker and Portainer migration script.
- `scripts/setup_golden_image.sh` and `.md` - the older flow, which hardened a hand-installed VM from the inside
  before turning it into a template. Kept for reference; its private-repository token steps no longer apply.

## Keys

Public keys live in [`keys/`](keys/), one file per account. See [`keys/README.md`](keys/README.md).
