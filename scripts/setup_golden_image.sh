#!/bin/bash
set -eux

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root. Please use 'sudo' or run as root user."
    exit 1
fi

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

# Preconfigure Unattended Upgrades (No Prompt)
echo "Configuring Unattended Upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

# Enable unattended-upgrades
systemctl enable --now unattended-upgrades

# Configure Needrestart to auto-restart services
echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/restart.conf

# Enable QEMU Guest Agent for Proxmox
systemctl enable --now qemu-guest-agent

# Harden SSH (Avoid Duplicates)
echo "Configuring SSH Security..."
sed -i 's/^#*\(PermitRootLogin\).*/\1 prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*\(PasswordAuthentication\).*/\1 no/' /etc/ssh/sshd_config
sed -i 's/^#*\(ChallengeResponseAuthentication\).*/\1 no/' /etc/ssh/sshd_config
grep -qxF "MaxAuthTries 3" /etc/ssh/sshd_config || echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
systemctl restart sshd

# Configure Fail2Ban (Only If Missing)
if [ ! -f "/etc/fail2ban/jail.local" ]; then
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
bantime = 3600
findtime = 600
maxretry = 5
EOF
    systemctl restart fail2ban
fi

# Enable Recidive Mode (Only If Missing)
if [ ! -f "/etc/fail2ban/jail.d/recidive.conf" ]; then
    cat > /etc/fail2ban/jail.d/recidive.conf <<EOF
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 86400  # 1-day ban
findtime = 86400
maxretry = 5
EOF
    systemctl restart fail2ban
fi

# Create Ansible User (If Not Exists)
if ! id "ansible" &>/dev/null; then
    echo "Creating Ansible User..."
    useradd -m -s /bin/bash ansible
    echo "ansible ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ansible
fi

# Ensure Cloud-Init Doesn't Override Ansible User
if ! grep -q "ansible" /etc/cloud/cloud.cfg; then
    echo "Adding Ansible User to Cloud-Init..."
    sed -i '/disable_root:/a - ansible' /etc/cloud/cloud.cfg
fi

# Disable Root Login after Cloud-Init
echo "passwd: { root: locked }" > /etc/cloud/cloud.cfg.d/99-disable-root.cfg

# Kernel Hardening via Sysctl (Avoid Duplicates)
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

# Cloud-Init Cleanup for VM Cloning (Only If Needed)
if [ -d "/var/lib/cloud/instances" ]; then
    cloud-init clean
    rm -rf /var/lib/cloud/instances /var/lib/cloud/seed /var/lib/cloud/instance
fi

# Clear machine ID for uniqueness in clones (Only If Needed)
if [[ ! -f "/etc/machine-id" || "$(stat -c %s /etc/machine-id)" -eq 0 ]]; then
    truncate -s 0 /etc/machine-id
fi

# Clean Up
apt autoremove -y
apt clean

echo "Golden Image Setup Completed Successfully!"
