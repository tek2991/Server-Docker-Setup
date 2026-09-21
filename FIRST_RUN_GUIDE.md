# First-Run Execution Guide: Multi-App Laravel Docker Hosting on OCI

This guide provides a linear, copy-pasteable walkthrough for setting up your Oracle Cloud Infrastructure (OCI) Ampere A1 (ARM64) instance from the initial SSH login through to running your first live application behind Caddy.

---

## Pre-Flight Checklist: Cloud Console Ingress Rules

In the **Oracle Cloud Console**, verify your VCN Default Security List has the following stateful ingress rules before starting:

* **Port 22 (TCP)** — SSH (restrict to your office/home IP if possible).
* **Port 80 (TCP)** — HTTP (from `0.0.0.0/0` or office/VPN CIDR).
* **Port 443 (TCP)** — HTTPS (from `0.0.0.0/0` or office/VPN CIDR).

---

## Phase 1: Connect & Initialize Host

### 1.1 SSH into your OCI Instance
```bash
ssh ubuntu@<instance-public-ip>
```

### 1.2 Prepare `/opt/sites` and Clone the Repository
```bash
sudo mkdir -p /opt/sites
sudo chown -R $USER:$USER /opt/sites

# Clone repository directly into /opt/sites
git clone https://github.com/tek2991/Server-Docker-Setup.git /opt/sites
cd /opt/sites
```

### 1.3 Run the Automated Host Initializer
Run the initialization script to configure the OCI firewall, 4GB swap, Docker Engine, and shared Docker networks:
```bash
chmod +x scripts/setup-host.sh
./scripts/setup-host.sh
```

### 1.4 Activate Non-Root Docker Permissions
```bash
newgrp docker
```

### 1.5 Quick Verification
```bash
docker --version
docker compose version
docker network ls
```
*(Confirm that both `web` and `internal` networks exist).*

---

## Phase 2: Build the Shared PHP Base Image

Build the unified PHP 8.3-FPM base image (includes `intl`, `exif`, `redis`, `gd`, `zip`, `opcache`, and `pdo_mysql`):

```bash
cd /opt/sites/shared-php
docker build -t sites-infra/shared-php-base:latest .
```

Verify build output:
```bash
docker image ls sites-infra/shared-php-base:latest
```

---

## Phase 3: Launch Shared Services (MariaDB 11 + Redis 7)

### 3.1 Generate the Database Root Password
```bash
cd /opt/sites/shared/secrets
openssl rand -base64 24 > db_root_password.txt
chmod 600 db_root_password.txt
```

### 3.2 (Optional) Review Tenant Passwords
Review the multi-tenant initialization script:
```bash
cat /opt/sites/shared/init/01-create-dbs.sql
```
*(Default passwords like `change_me_dwelly`, `change_me_site_b`, etc., can be edited before the initial launch).*

### 3.3 Launch Shared Containers
```bash
cd /opt/sites/shared
docker compose up -d
```

### 3.4 Verify Health
```bash
docker compose ps
```
Test MariaDB CLI connection:
```bash
docker exec -it shared-mariadb mariadb -u root -p"$(cat secrets/db_root_password.txt)" -e "SHOW DATABASES;"
```
*(Databases `dwelly`, `site_b`, `site_c`, and `site_d` should be present).*

Test Redis:
```bash
docker exec -it shared-redis redis-cli ping
```
*(Expected output: `PONG`).*

---

## Phase 4: Deploy the First Application (`dwelly`)

### 4.1 Clone the Application Codebase
Clone Dwelly into `dwelly/src`:
```bash
cd /opt/sites/dwelly
git clone git@github.com:tek2991/Dwelly-V2.git src
```
*(If prompted for SSH keys, ensure your GitHub deploy key or SSH agent forwarding is enabled).*

### 4.2 Configure Production Environment (`.env`)
```bash
cp .env.example .env
nano .env
```
Ensure key variables match the shared infrastructure:
```dotenv
APP_NAME=Dwelly
APP_ENV=production
APP_DEBUG=false
APP_URL=https://dwelly.internal.example.com

DB_CONNECTION=mysql
DB_HOST=mariadb
DB_PORT=3306
DB_DATABASE=dwelly
DB_USERNAME=dwelly
DB_PASSWORD=change_me_dwelly

REDIS_CLIENT=phpredis
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_DB=0
REDIS_CACHE_DB=1

FILESYSTEM_DISK=public
```

If you need a new `APP_KEY`:
```bash
docker run --rm -v $(pwd)/src:/var/www/html sites-infra/shared-php-base:latest php artisan key:generate --show
```
Paste this key into `APP_KEY` in `.env`.

### 4.3 Run the Deployment Script
```bash
chmod +x deploy.sh
./deploy.sh
```

Verify that `dwelly-app` is running:
```bash
docker ps | grep dwelly-app
```

---

## Phase 5: Launch and Verify Caddy Reverse Proxy

### 5.1 Review `proxy/Caddyfile`
```bash
cd /opt/sites/proxy
nano Caddyfile
```
Set your real domain or testing hostname for `dwelly`. 
> [!TIP]
> For initial local testing with the server IP before public DNS propagates, you can temporarily use:
> ```caddy
> :80 {
>     import common_settings
>     root * /srv/dwelly/public
>     php_fastcgi dwelly-app:9000 {
>         root /var/www/html/public
>     }
>     file_server
> }
> ```

### 5.2 Start Caddy
```bash
docker compose up -d
```

### 5.3 Test HTTP Routing
```bash
curl -I http://localhost
```
*(Expected response: `HTTP/1.1 200 OK` or `302 Found` to login).*

---

## Phase 6: Host Crontab Setup (Scheduler & Nightly Backups)

To run the Laravel scheduler and daily backups at 0 MB extra background RAM overhead:

### 6.1 Create the Backup Script
```bash
sudo mkdir -p /opt/scripts /opt/backups
sudo chown -R $USER:$USER /opt/scripts /opt/backups

cat << 'EOF' > /opt/scripts/backup-dbs.sh
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/opt/backups"
TIMESTAMP=$(date +%F_%H%M%S)
ROOT_PASS=$(cat /opt/sites/shared/secrets/db_root_password.txt)

mkdir -p "$BACKUP_DIR"

for db in dwelly site_b site_c site_d; do
    if docker exec shared-mariadb mariadb -u root -p"$ROOT_PASS" -e "USE $db" 2>/dev/null; then
        docker exec shared-mariadb mariadbdump -u root -p"$ROOT_PASS" \
            --single-transaction --quick "$db" | gzip > "$BACKUP_DIR/${db}_${TIMESTAMP}.sql.gz"
    fi
done

# Keep only last 14 days of backups
find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +14 -delete
EOF

chmod +x /opt/scripts/backup-dbs.sh
```

### 6.2 Configure Host Crontab
Open host crontab:
```bash
crontab -e
```
Add the following entries:
```cron
# Laravel Task Schedulers (runs every minute)
* * * * * docker exec -t dwelly-app php artisan schedule:run >> /var/log/dwelly-schedule.log 2>&1

# Nightly MariaDB Backup (runs daily at 2:00 AM)
0 2 * * * /opt/scripts/backup-dbs.sh > /dev/null 2>&1
```

---

## Phase 7: Golden Verification Checklist

Run this quick command to verify container health and RAM consumption:
```bash
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

Expected output:
| Container Name | Typical CPU | Typical Memory |
| :--- | :--- | :--- |
| `caddy-proxy` | `< 0.5%` | `~30 MB` |
| `shared-mariadb` | `< 1.0%` | `~350 MB` |
| `shared-redis` | `< 0.1%` | `~15 MB` |
| `dwelly-app` | `0.0%` (idle) | `~40 MB` |

**Total Memory in Use:** ~500 MB (leaving over 11 GB of RAM free on your 12 GB instance).
