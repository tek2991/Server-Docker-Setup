# Master Docker Setup: 4 Internal Laravel Apps on OCI (2 vCPU / 12GB ARM64)

This repository manages the production-ready container infrastructure for running 4 isolated internal Laravel applications (`dwelly`, `site-b`, `site-c`, `site-d`) behind a single shared reverse proxy (**Caddy**) with shared **MariaDB 11** and **Redis 7** services on an Oracle Cloud Infrastructure (OCI) Ampere A1 (ARM64) instance.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Directory Structure](#directory-structure)
3. [Cloud Prerequisites & Firewall (OCI Console)](#cloud-prerequisites--firewall-oci-console)
4. [Step 1: Host Preparation (OCI Instance)](#step-1-host-preparation-oci-instance)
   - [1.1 Connect via SSH](#11-connect-via-ssh)
   - [1.2 Clone Repository to `/opt/sites`](#12-clone-repository-to-optsites)
   - [1.3 Automated Host Setup (Recommended)](#13-automated-host-setup-recommended)
   - [1.4 Manual Host Setup (Alternative)](#14-manual-host-setup-alternative)
5. [Step 2: Build the Shared PHP Base Image](#step-2-build-the-shared-php-base-image)
6. [Step 3: Configure and Start Shared Services (MariaDB + Redis)](#step-3-configure-and-start-shared-services-mariadb--redis)
   - [3.1 Set Database Root Password](#31-set-database-root-password)
   - [3.2 Review Multi-Tenant Database Initialization](#32-review-multi-tenant-database-initialization)
   - [3.3 Launch Shared Stack](#33-launch-shared-stack)
   - [3.4 Verify Database & Redis Health](#34-verify-database--redis-health)
7. [Step 4: Deploy Applications (Example: Dwelly)](#step-4-deploy-applications-example-dwelly)
   - [4.1 Clone Application Repository](#41-clone-application-repository)
   - [4.2 Configure Production Environment (`.env`)](#42-configure-production-environment-env)
   - [4.3 Run Automated Deployment Script](#43-run-automated-deployment-script)
   - [4.4 Deploying Sibling Sites (`site-b`, `site-c`, `site-d`)](#44-deploying-sibling-sites-site-b-site-c-site-d)
8. [Step 5: Configure and Start Caddy Reverse Proxy](#step-5-configure-and-start-caddy-reverse-proxy)
   - [5.1 Review & Update Domains in `Caddyfile`](#51-review--update-domains-in-caddyfile)
   - [5.2 Launch Caddy Proxy](#52-launch-caddy-proxy)
   - [5.3 Verify Routing & SSL](#53-verify-routing--ssl)
9. [Step 6: Laravel Scheduler Management](#step-6-laravel-scheduler-management)
   - [Option A: Host Crontab (Recommended: 0 MB Extra RAM)](#option-a-host-crontab-recommended-0-mb-extra-ram)
   - [Option B: Shared Docker Container](#option-b-shared-docker-container)
10. [Step 7: Automated Nightly Database Backups](#step-7-automated-nightly-database-backups)
11. [Step 8: Day-to-Day Operations & Maintenance](#step-8-day-to-day-operations--maintenance)
    - [Redeploying Code Updates](#redeploying-code-updates)
    - [Running Artisan Commands](#running-artisan-commands)
    - [Viewing Container Logs](#viewing-container-logs)
    - [Resource & Memory Monitoring](#resource--memory-monitoring)
12. [Step 9: Troubleshooting Common Issues](#step-9-troubleshooting-common-issues)
13. [Step 10: Performance Calibration Reference](#step-10-performance-calibration-reference)

---

## Architecture Overview

```text
                        ┌────────────────────────┐
                        │      Caddy Proxy       │
                        │    (Ports 80 / 443)    │
                        └───────────┬────────────┘
                         web network│
        ┌────────────┬──────────────┼──────────────┬────────────┐
        │            │              │              │            │
   ┌────▼────┐  ┌────▼────┐    ┌────▼────┐    ┌────▼────┐       │
   │ dwelly  │  │ site-b  │    │ site-c  │    │ site-d  │       │
   │  app    │  │  app    │    │  app    │    │  app    │       │
   └────┬────┘  └────┬────┘    └────┬────┘    └────┬────┘       │
        │            │              │              │            │
        └────────────┴──────internal network───────┴────────────┘
                                    │
                    ┌───────────────┼───────────────┐
              ┌─────▼─────┐   ┌─────▼─────┐   ┌─────▼─────┐
              │  MariaDB  │   │   Redis   │   │ Scheduler │
              │  (shared) │   │ (shared)  │   │  (shared) │
              └───────────┘   └───────────┘   └───────────┘
```

### Key Architectural Highlights
- **Zero Static Overhead on PHP**: Caddy directly serves compiled CSS/JS/Vite bundles and uploaded media from the host filesystem with Gzip and Zstandard compression. PHP-FPM processes dynamic script execution exclusively.
- **Unified ARM64 PHP Base Image**: Built once locally, saving ~75% disk space across the 4 applications.
- **Isolated Multi-Tenant Databases**: Each app has its own isolated MariaDB database and dedicated MySQL user on the `internal` bridge network.
- **Resource Guardrails**: Strict memory and CPU limits prevent any rogue query or background worker from crashing sibling applications.

---

## Directory Structure

The master repository is designed to reside directly at `/opt/sites`. Sibling applications are cloned into their respective `<app>/src` subdirectories:

```text
/opt/sites/
├── README.md
├── scripts/
│   ├── setup-host.sh            # Automated OCI host initializer
│   └── backup-dbs.sh            # Automated nightly MariaDB backup script
├── proxy/
│   ├── docker-compose.yml       # Caddy reverse proxy service
│   └── Caddyfile                # FastCGI bridge & static asset file server
├── shared/
│   ├── docker-compose.yml       # MariaDB 11, Redis 7, and shared scheduler
│   ├── init/
│   │   └── 01-create-dbs.sql    # Multi-tenant DB & user bootstrap script
│   └── secrets/
│       ├── .gitignore
│       ├── db_root_password.txt.example
│       └── db_root_password.txt # Host-only secret (gitignored)
├── shared-php/
│   └── Dockerfile               # Base PHP 8.3-FPM with intl, exif, redis, etc.
├── dwelly/
│   ├── docker-compose.yml       # Dwelly PHP-FPM container definition
│   ├── deploy.sh                # Automated zero-downtime release script
│   ├── .env.example
│   ├── .env                     # Production environment variables (gitignored)
│   └── src/                     # Cloned Dwelly-V2 repository
└── site-b/  site-c/  site-d/    # Sibling application directories
```

---

## Cloud Prerequisites & Firewall (OCI Console)

Before running commands on the virtual machine, configure the **OCI Cloud-Level Firewall (Security List / Network Security Group)**.

In the Oracle Cloud Console:
1. Navigate to: **Networking → Virtual Cloud Networks → Your VCN → Security Lists → Default Security List**.
2. Click **Add Ingress Rules** and add the following rules:

| Stateless | Source Type | Source CIDR | IP Protocol | Source Port Range | Destination Port Range | Description |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| No | CIDR | `0.0.0.0/0` (or your IP) | TCP | All | **22** | SSH Host Management |
| No | CIDR | `0.0.0.0/0` (or Office/VPN CIDR) | TCP | All | **80** | HTTP Web Traffic / ACME challenge |
| No | CIDR | `0.0.0.0/0` (or Office/VPN CIDR) | TCP | All | **443** | HTTPS Web Traffic |

> [!TIP]
> Since these are internal applications, you can restrict the Source CIDR for ports 80 and 443 to your office public IP or corporate VPN CIDR block for enhanced security.

---

## Step 1: Host Preparation (OCI Instance)

### 1.1 Connect via SSH
Connect to your OCI Ubuntu instance from your local workstation:
```bash
ssh ubuntu@<instance-public-ip>
```

### 1.2 Clone Repository to `/opt/sites`
Prepare the `/opt/sites` directory with non-root user ownership, then clone this repository:
```bash
sudo mkdir -p /opt/sites
sudo chown -R $USER:$USER /opt/sites

git clone https://github.com:tek2991/Server-Docker-Setup.git /opt/sites
cd /opt/sites
```

### 1.3 Automated Host Setup (Recommended)
We provide an automated setup script that configures system packages, OCI iptables rules, 4GB swap, Docker Engine, external Docker networks, and fail2ban:
```bash
chmod +x scripts/setup-host.sh
./scripts/setup-host.sh
```

Apply non-root Docker group permissions immediately without logging out:
```bash
newgrp docker
```

Verify that Docker and Compose are functional:
```bash
docker --version
docker compose version
docker network ls
```
*(You should see both `web` and `internal` listed in the output).*

---

### 1.4 Manual Host Setup (Alternative)
If you prefer executing the host initialization commands manually instead of running the script:

#### A. System Updates & Prerequisites
```bash
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get install -y curl git fail2ban iptables-persistent netfilter-persistent ca-certificates
```

#### B. Fix OCI Local `iptables` Firewall
> [!IMPORTANT]
> OCI Ubuntu images ship with default `iptables` rules that drop all incoming traffic on ports other than 22, even when the cloud security list allows it. You must explicitly open ports 80 and 443 locally:
```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```
*(Do not enable UFW without configuring Docker forward rules, as UFW defaults `DEFAULT_FORWARD_POLICY="DROP"`, breaking Docker container-to-container bridges).*

#### C. Configure 4GB Swap Safety Net
Ensures your 12GB RAM instance never suffers kernel Out-Of-Memory (OOM) kills during heavy migrations or traffic surges:
```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl vm.swappiness=10
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.d/99-swappiness.conf
free -h
```

#### D. Install Official Docker Engine & Compose Plugin
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
sudo systemctl enable --now docker
newgrp docker
```

#### E. Provision Shared Docker Networks
```bash
docker network create web
docker network create internal
```

---

## Step 2: Build the Shared PHP Base Image

All 4 applications share a unified PHP 8.3-FPM base image containing Composer 2 and all required extensions (`intl` for Filament 5, `exif` for Spatie Media Library, `redis`, `gd`, `zip`, `opcache`, `bcmath`, and `pdo_mysql`):

```bash
cd /opt/sites/shared-php
docker build -t sites-infra/shared-php-base:latest .
```

Verify that the image built successfully:
```bash
docker image ls sites-infra/shared-php-base
```

---

## Step 3: Configure and Start Shared Services (MariaDB + Redis)

### 3.1 Set Database Root Password
Generate a secure secret file for the MariaDB root password:
```bash
cd /opt/sites/shared/secrets
cp db_root_password.txt.example db_root_password.txt
```
Edit `db_root_password.txt` or generate a random 24-character string:
```bash
openssl rand -base64 24 > db_root_password.txt
chmod 600 db_root_password.txt
```

### 3.2 Review Multi-Tenant Database Initialization
The file `/opt/sites/shared/init/01-create-dbs.sql` is automatically mounted into `/docker-entrypoint-initdb.d` inside MariaDB. On the initial startup, MariaDB provisions all 4 databases and users:
- `dwelly` (User: `dwelly`, Database: `dwelly`)
- `site_b` (User: `site_b`, Database: `site_b`)
- `site_c` (User: `site_c`, Database: `site_c`)
- `site_d` (User: `site_d`, Database: `site_d`)

If you want custom passwords for these app users, edit `shared/init/01-create-dbs.sql` **before** the first container launch:
```bash
nano /opt/sites/shared/init/01-create-dbs.sql
```

### 3.3 Launch Shared Stack
```bash
cd /opt/sites/shared
docker compose up -d
```

### 3.4 Verify Database & Redis Health
Verify the containers are healthy and running:
```bash
docker compose ps
```
Test the MariaDB root connection and verify all databases were created:
```bash
docker exec -it shared-mariadb mariadb -u root -p"$(cat secrets/db_root_password.txt)" -e "SHOW DATABASES;"
```
*(You should see `dwelly`, `site_b`, `site_c`, and `site_d` in the database list).*

Test Redis responsiveness:
```bash
docker exec -it shared-redis redis-cli ping
```
*(Expected response: `PONG`).*

---

## Step 4: Deploy Applications (Example: Dwelly)

Each application follows a consistent, reproducible deployment structure. Here is how to deploy Dwelly:

### 4.1 Clone Application Repository
Clone the application source code directly into `dwelly/src`:
```bash
cd /opt/sites/dwelly
git clone git@github.com:tek2991/Dwelly-V2.git src
```

### 4.2 Configure Production Environment (`.env`)
Create the production `.env` file from the example:
```bash
cp .env.example .env
nano .env
```

Ensure the database, cache, and URL configuration match the shared stack:
```dotenv
APP_NAME=Dwelly
APP_ENV=production
APP_DEBUG=false
APP_URL=https://dwelly.internal.example.com

# Shared MariaDB Stack
DB_CONNECTION=mysql
DB_HOST=mariadb
DB_PORT=3306
DB_DATABASE=dwelly
DB_USERNAME=dwelly
DB_PASSWORD=change_me_dwelly

# Shared Redis Stack
REDIS_CLIENT=phpredis
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=null
REDIS_DB=0
REDIS_CACHE_DB=1

FILESYSTEM_DISK=public
```

If you need to generate an `APP_KEY` for a fresh installation:
```bash
docker run --rm -v $(pwd)/src:/var/www/html sites-infra/shared-php-base:latest php artisan key:generate --show
```
*(Copy the generated key into `APP_KEY` in your `.env` file).*

### 4.3 Run Automated Deployment Script
Make `deploy.sh` executable and run it:
```bash
chmod +x deploy.sh
./deploy.sh
```

**What `deploy.sh` performs automatically:**
1. Pulls the latest commits from the Git repository.
2. Builds the production Docker image using a multi-stage build (compiles Tailwind CSS & Vite assets via Node 22, installs production Composer dependencies).
3. Copies compiled frontend assets (`public/build`) from the container to the host filesystem so Caddy can serve them at native speeds.
4. Runs database migrations: `php artisan migrate --force`.
5. Creates the storage symlink: `php artisan storage:link`.
6. Optimizes configuration, routing, and blade view caches: `config:cache`, `route:cache`, `view:cache`.
7. Optimizes Filament components and icons: `filament:optimize`.
8. Starts/restarts the application container (`dwelly-app`).

---

### 4.4 Deploying Sibling Sites (`site-b`, `site-c`, `site-d`)
Deploying sibling sites follows the exact same workflow:
1. `cd /opt/sites/site-b && git clone <repo-url> src`
2. `cp .env.example .env` and adjust database credentials (`DB_DATABASE=site_b`, `DB_USERNAME=site_b`) and assign a unique Redis database index to avoid key collisions:
   - `site-b`: `REDIS_DB=2`, `REDIS_CACHE_DB=3`
   - `site-c`: `REDIS_DB=4`, `REDIS_CACHE_DB=5`
   - `site-d`: `REDIS_DB=6`, `REDIS_CACHE_DB=7`
3. Run `./deploy.sh`.

---

## Step 5: Configure and Start Caddy Reverse Proxy

### 5.1 Review & Update Domains in `Caddyfile`
Open `/opt/sites/proxy/Caddyfile`:
```bash
cd /opt/sites/proxy
nano Caddyfile
```
Replace the placeholder domain names with your actual hostnames or internal DNS records:
```caddy
dwelly.yourdomain.com {
    import common_settings
    root * /srv/dwelly/public

    php_fastcgi dwelly-app:9000 {
        root /var/www/html/public
    }

    file_server
}
```

> [!NOTE]
> If your domains have public DNS records pointing to your OCI instance IP, Caddy will **automatically obtain and renew Let's Encrypt / ZeroSSL TLS certificates**.
> If you are using internal IP addresses or testing locally without a public domain, you can use:
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

### 5.2 Launch Caddy Proxy
Start the Caddy reverse proxy container:
```bash
docker compose up -d
```

### 5.3 Verify Routing & SSL
Check Caddy logs to confirm certificate issuance and routing:
```bash
docker compose logs -f caddy
```
Test HTTP request routing locally on the server:
```bash
curl -I http://localhost
```

---

## Step 6: Laravel Scheduler Management

Laravel cron tasks (e.g. queue cleanups, scheduled reports, backups) need to be triggered once every minute (`php artisan schedule:run`).

### Option A: Host Crontab (Recommended: 0 MB Extra RAM)
Running artisan schedules directly via the host's system cron consumes zero background RAM and triggers jobs on demand.

1. Stop the scheduler container in `shared`:
   ```bash
   cd /opt/sites/shared
   docker compose stop scheduler
   ```
2. Open host crontab:
   ```bash
   crontab -e
   ```
3. Add the following entries:
   ```cron
   * * * * * docker exec -t dwelly-app php artisan schedule:run >> /var/log/dwelly-schedule.log 2>&1
   * * * * * docker exec -t site-b-app php artisan schedule:run >> /var/log/site-b-schedule.log 2>&1
   * * * * * docker exec -t site-c-app php artisan schedule:run >> /var/log/site-c-schedule.log 2>&1
   * * * * * docker exec -t site-d-app php artisan schedule:run >> /var/log/site-d-schedule.log 2>&1
   ```

---

### Option B: Shared Docker Container
If you prefer not to touch the host crontab, the `shared-scheduler` container in `/opt/sites/shared/docker-compose.yml` automatically scans `/apps/*/artisan` every 60 seconds and triggers `schedule:run`.

Monitor scheduler execution:
```bash
docker compose logs -f scheduler
```

---

## Step 7: Automated Nightly Database Backups

Automate daily backups of all tenant databases with automatic compression and a 14-day retention cycle.

1. Create the backup script directory:
   ```bash
   sudo mkdir -p /opt/scripts /opt/backups
   sudo chown -R $USER:$USER /opt/scripts /opt/backups
   ```

2. Create `/opt/scripts/backup-dbs.sh`:
   ```bash
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

   # Delete backups older than 14 days
   find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +14 -delete
   EOF

   chmod +x /opt/scripts/backup-dbs.sh
   ```

3. Test run the backup script:
   ```bash
   /opt/scripts/backup-dbs.sh
   ls -lh /opt/backups
   ```

4. Add to host crontab (`crontab -e`) to execute nightly at 2:00 AM:
   ```cron
   0 2 * * * /opt/scripts/backup-dbs.sh > /dev/null 2>&1
   ```

---

## Step 8: Day-to-Day Operations & Maintenance

### Redeploying Code Updates
Whenever you push changes to an application repository:
```bash
cd /opt/sites/dwelly
./deploy.sh
```

### Running Artisan Commands
Execute any Artisan command inside a running container using `docker exec`:
```bash
# Run database seeders
docker exec -it dwelly-app php artisan db:seed

# Clear application cache manually
docker exec -it dwelly-app php artisan cache:clear

# Check schedule list
docker exec -it dwelly-app php artisan schedule:list

# Open Laravel Tinker
docker exec -it dwelly-app php artisan tinker
```

### Viewing Container Logs
```bash
# Live logs for an application
docker logs -f dwelly-app

# Caddy access and error logs
docker logs -f caddy-proxy

# MariaDB error logs
docker logs -f shared-mariadb

# Redis logs
docker logs -f shared-redis
```

### Resource & Memory Monitoring
Monitor real-time CPU and memory usage across all containers:
```bash
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

Under normal idle conditions, the entire stack consumes **~2.0 GB RAM**, leaving **~10 GB of memory headroom** on your 12GB OCI instance for heavy traffic bursts and Filament operations.

---

## Step 9: Troubleshooting Common Issues

### 1. Caddy Returns `502 Bad Gateway`
- **Cause**: The PHP-FPM container is stopped or cannot be resolved on the `web` Docker network.
- **Check**:
  ```bash
  docker ps | grep dwelly-app
  docker network inspect web | grep dwelly-app
  ```
- **Fix**: Verify `dwelly/docker-compose.yml` connects to the `web` network and restart the container:
  ```bash
  cd /opt/sites/dwelly && docker compose up -d
  ```

### 2. Database Connection Refused (`SQLSTATE[HY000] [2002]`)
- **Cause**: The app container is not connected to the `internal` network, or `DB_HOST` in `.env` is set to `127.0.0.1` instead of `mariadb`.
- **Fix**: Ensure `.env` specifies `DB_HOST=mariadb` and `DB_PORT=3306`. Check container network attachment:
  ```bash
  docker network inspect internal | grep dwelly-app
  ```

### 3. File Permissions / Storage Write Errors
- **Cause**: The container runs as `www-data` (UID 82 on Alpine), but mounted host storage directories have mismatched ownership.
- **Fix**:
  ```bash
  docker exec -it dwelly-app chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache
  docker exec -it dwelly-app chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache
  ```

### 4. Styles or JavaScript (Vite Build) Missing on Frontend
- **Cause**: Caddy serves static files directly from host disk (`/srv/dwelly/public`), but `public/build` was not copied out during build.
- **Fix**: Run `./deploy.sh` (which automatically runs `docker cp` to extract `public/build` from the container image to host `src/public/build`).

---

## Step 10: Performance Calibration Reference

This infrastructure has been pre-configured to sustain **200 concurrent active connections** and **20MB file uploads**:

| Component | Setting | Value | Rationale |
| :--- | :--- | :--- | :--- |
| **MariaDB** | `max_connections` | `250` | Safely absorbs 200+ concurrent requests without connection rejection. |
| **MariaDB** | `innodb_buffer_pool_size` | `512M` | Keeps active working index and dataset resident in RAM for instant queries. |
| **MariaDB** | `table_open_cache` | `1000` | Eliminates table file descriptor re-opening overhead. |
| **Caddy** | `request_body max_size` | `30MB` | Ample headroom for 20MB file uploads plus multipart boundaries and headers. |
| **Caddy** | `encode` | `gzip zstd` | Modern compression reduces bandwidth consumption on large JSON/CSS/JS payloads. |
| **PHP-FPM** | `pm` | `ondemand` | Spawns worker processes dynamically on request, scaling down to ~30MB RAM when idle. |
| **PHP-FPM** | `pm.max_children` | `25` per app | Accommodates traffic spikes without exhausting host memory (4 apps × 25 = 100 max workers). |
| **PHP-FPM** | `upload_max_filesize` | `25M` | Allows single uploads up to 25MB. |
| **PHP-FPM** | `post_max_size` | `30M` | Allows multipart POST payload sizes up to 30MB. |
| **Host VM** | `vm.swappiness` | `10` | Restricts swap utilization strictly to extreme memory emergencies. |
