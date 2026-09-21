#!/usr/bin/env bash
# ==============================================================================
# OCI Ubuntu ARM64 (Ampere A1) Server Initialization Script
# For: Multi-App Laravel Docker Infrastructure (Server-Docker-Setup)
# ==============================================================================
set -euo pipefail

echo "=========================================================="
echo " Starting OCI Host Setup for Server-Docker-Setup"
echo "=========================================================="

# 1. Update system packages
echo "--> Updating system packages..."
sudo apt-get update -y && sudo apt-get upgrade -y

# 2. Install essential utilities and iptables-persistent
echo "--> Installing utilities, fail2ban, and iptables-persistent..."
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
    curl \
    git \
    fail2ban \
    iptables-persistent \
    netfilter-persistent \
    ca-certificates

# 3. Configure OCI Local iptables (OCI Ubuntu drops ports 80/443 by default)
echo "--> Configuring iptables for ports 80 and 443..."
# Check if port 80 rule already exists
if ! sudo iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
    # Insert before the default OCI reject rule (typically rule 6 or fallback to top)
    sudo iptables -I INPUT 6 -p tcp -m state --state NEW --dport 80 -j ACCEPT 2>/dev/null \
        || sudo iptables -I INPUT 1 -p tcp -m state --state NEW --dport 80 -j ACCEPT
fi

if ! sudo iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 6 -p tcp -m state --state NEW --dport 443 -j ACCEPT 2>/dev/null \
        || sudo iptables -I INPUT 1 -p tcp -m state --state NEW --dport 443 -j ACCEPT
fi

sudo netfilter-persistent save

# 4. Set up 4GB Swap File and tune swappiness
if [ ! -f /swapfile ]; then
    echo "--> Creating 4GB swapfile..."
    sudo fallocate -l 4G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    # Lower swappiness so swap is only used during high memory pressure
    sudo sysctl vm.swappiness=10
    echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.d/99-swappiness.conf
else
    echo "--> Swapfile already exists. Skipping creation."
fi

# 5. Install Docker Engine and Docker Compose plugin
if ! command -v docker &> /dev/null; then
    echo "--> Installing Docker Engine and Docker Compose..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    sudo systemctl enable --now docker
else
    echo "--> Docker is already installed."
fi

# 6. Ensure Docker networks exist
echo "--> Provisioning shared Docker networks..."
sudo docker network create web 2>/dev/null || echo "Network 'web' already exists."
sudo docker network create internal 2>/dev/null || echo "Network 'internal' already exists."

# 7. Configure Fail2ban
echo "--> Enabling Fail2ban for SSH protection..."
sudo systemctl enable --now fail2ban

# 8. Setup /opt/sites directory structure
echo "--> Ensuring /opt/sites exists with current user permissions..."
sudo mkdir -p /opt/sites
sudo chown -R "$USER":"$USER" /opt/sites

echo "=========================================================="
echo " Host Setup Complete!"
echo " IMPORTANT: Run 'newgrp docker' or log out & back in"
echo " for non-root Docker commands to take effect."
echo "=========================================================="
