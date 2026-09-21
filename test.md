🚀 Complete Step-by-Step Execution Plan
I have added an automated

setup-host.sh
script to your repository and pushed it to GitHub. Here is the streamlined flow:

Step 1: OCI Cloud Firewall (Console)
In the OCI Web Console: Networking → Virtual Cloud Networks → Your VCN → Security Lists (Default Security List):

Add Ingress Rule:
Port 22 (TCP) — SSH (restrict to your IP if possible)
Port 80 (TCP) — HTTP (from 0.0.0.0/0 or office/VPN CIDR)
Port 443 (TCP) — HTTPS (from 0.0.0.0/0 or office/VPN CIDR)
Step 2: Connect & Run the Automated Host Setup
SSH into your instance:

bash
ssh ubuntu@<instance-public-ip>
Clone your repository into /opt/sites and run the setup script:

bash
sudo mkdir -p /opt/sites
sudo chown -R $USER:$USER /opt/sites

# Clone your infrastructure repo

git clone https://github.com/tek2991/Server-Docker-Setup.git /opt/sites
cd /opt/sites

# Run the host initialization script

./scripts/setup-host.sh

# Activate docker group permissions without logging out

newgrp docker
What this script does automatically:

Runs apt update && apt upgrade -y.
Installs curl, git, fail2ban, and iptables-persistent.
Safely unlocks ports 80/443 in OCI's local iptables and persists them.
Creates and activates the 4GB swapfile (with vm.swappiness=10).
Installs official Docker Engine + Docker Compose plugin for ARM64.
Creates the external Docker networks: web and internal.
Step 3: Build the Unified PHP Base Image
bash
cd /opt/sites/shared-php
docker build -t sites-infra/shared-php-base:latest .
(All extensions intl, exif, redis, gd, opcache, pdo_mysql compile cleanly on ARM64).

Step 4: Configure & Start MariaDB + Redis
Set the root database password:
bash
cd /opt/sites/shared/secrets
cp db_root_password.txt.example db_root_password.txt
nano db_root_password.txt # Set your secure root password
(Optional) Review /opt/sites/shared/init/01-create-dbs.sql to customize database passwords for each tenant.
Start the shared services:
bash
cd /opt/sites/shared
docker compose up -d
Step 5: Deploy Dwelly
Clone Dwelly's codebase into dwelly/src:
bash
cd /opt/sites/dwelly
git clone git@github.com:tek2991/Dwelly-V2.git src
Configure .env:
bash
cp .env.example .env
nano .env # Set your APP_KEY, DB_PASSWORD, APP_URL, etc.
Run the automated deployment script:
bash
chmod +x deploy.sh
./deploy.sh
(This builds the production image, compiles Vite/Tailwind assets, extracts public builds for Caddy, runs migrations, creates storage links, and pre-warms Laravel caches).
Step 6: Start Caddy Reverse Proxy
Review /opt/sites/proxy/Caddyfile and ensure the domain matches your DNS / internal hostname (or public IP for initial testing):
bash
cd /opt/sites/proxy
nano Caddyfile
Start Caddy:
bash
docker compose up -d
Step 7: Verify Everything Is Running
bash
docker stats --no-stream
You should see caddy-proxy, shared-mariadb, shared-redis, and dwelly-app healthy and using ~2GB of RAM with 10GB+ free headroom!
