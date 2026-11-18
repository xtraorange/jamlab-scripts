# Public keys

One file per account: `keys/<account>.pub`, one public key per line (public keys only, never private keys).

- `ansible.pub` - the keys Ansible connects with. The Proxmox golden image puts these on its `ansible` account.

Anyone who can change a file here can log in as that account on every machine built from it, so keep write
access to this repository to yourself and use two-factor sign-in.
