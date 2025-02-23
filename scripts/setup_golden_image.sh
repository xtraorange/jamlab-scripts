#!/bin/bash
set -eux

echo "Starting Golden Image Setup..."

# Update and install required packages
apt update && apt upgrade -y

apt install -y \
    curl wget htop git vim tmux \
    fail2ban software-properties-common \
    net-tools zip unzip python3-pip \
    unattended-upgrades apt-transport-https \
    prometheus-node-exporter needrestart apparmor apparmor-utils \
    python3 cloud-init qemu-guest-agent \
    python3-apt python3-setuptools python3-venv

# Enable unattended upgrades
dpkg-reconfigure -plow unattended-upgrades

# Configure Needrestart to auto-restart services
echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/restart.conf

# Enable QEMU Guest Agent for Proxmox
systemctl enable --now qemu-guest-agent

# Harden SSH
echo "Configuring SSH Security..."
sed -i 's/^#*\(PermitRootLogin\).*/\1 no/' /etc/ssh/sshd_config
sed -i 's/^#*\(PasswordAuthentication\).*/\1 no/' /etc/ssh/sshd_config
sed -i 's/^#*\(ChallengeResponseAuthentication\).*/\1 no/' /etc/ssh/sshd_config
echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
echo "AllowUsers ansible" >> /etc/ssh/sshd_config
systemctl restart sshd

# Configure Fail2Ban
echo "Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
bantime = 3600
findtime = 600
maxretry = 5
EOF
systemctl restart fail2ban

# Enable Recidive Mode (Longer Ban for Repeat Offenders)
cat > /etc/fail2ban/jail.d/recidive.conf <<EOF
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 86400  # 1-day ban
findtime = 86400
maxretry = 5
EOF
systemctl restart fail2ban

# Create Ansible User (SSH Key will be added via Cloud-Init)
echo "Creating Ansible User..."
useradd -m -s /bin/bash ansible
echo "ansible ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ansible

# Install Teleport
echo "Installing Teleport..."
curl https://goteleport.com/static/install.sh | bash

# Disable Root Login
passwd -l root

# Kernel Hardening via Sysctl
echo "Applying Kernel Hardening Settings..."
cat > /etc/sysctl.d/99-security.conf <<EOF
# Disable ICMP redirects (security risk)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Disable source routing (security risk)
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1
EOF
sysctl --system

# Enable AppArmor
aa-enforce /etc/apparmor.d/*

# Enable Prometheus Node Exporter
systemctl enable --now prometheus-node-exporter

# Disable Unneeded Services (But Keep Avahi)
systemctl disable --now cups
systemctl disable --now bluetooth

# Cloud-Init Cleanup for VM Cloning
cloud-init clean --logs

# Clear machine ID for uniqueness in clones
rm -f /etc/machine-id
systemd-machine-id-setup

# Clean Up
apt autoremove -y
apt clean

echo "Golden Image Setup Completed Successfully!"
