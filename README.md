# Master Docker Setup: 4 Internal Laravel Apps on OCI (2 vCPU / 12GB)

This repository manages the master container infrastructure for running 4 isolated internal Laravel applications (`dwelly`, `site-b`, `site-c`, `site-d`) behind a single shared reverse proxy (Caddy) with shared MariaDB and Redis services on a single Oracle Cloud Infrastructure (OCI) instance.

---

## Architecture Overview

```
                        ┌────────────────────────┐
                        │     Caddy Proxy        │
                        │    (Ports 80/443)      │
                        └───────────┬────────────┘
                     web network    │
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

---

## Directory Structure

```text
server-docker-setup/
├── README.md
├── proxy/
│   ├── docker-compose.yml       # Caddy reverse proxy
│   └── Caddyfile                # FastCGI + static file_server routing
├── shared/
│   ├── docker-compose.yml       # MariaDB + Redis + scheduler container
│   ├── init/
│   │   └── 01-create-dbs.sql    # Multi-tenant DB & user provisioning
│   └── secrets/
│       ├── .gitignore
│       └── db_root_password.txt # (Create from example)
├── shared-php/
│   └── Dockerfile               # Unified PHP 8.3-FPM base with intl, exif, redis, etc.
├── dwelly/
│   ├── docker-compose.yml       # App container definition
│   ├── .env                     # Production environment variables (gitignored)
│   ├── .env.example
│   ├── deploy.sh                # Automated release & cache script
│   └── src/                     # Cloned Dwelly-V2 repository
└── site-b/  site-c/  site-d/    # Sibling application stacks
```

---

## 1. Initial Host Setup (OCI Instance)

### 1.1 Automated Setup (Recommended)
You can automate all host prerequisites (system updates, OCI local iptables for ports 80/443, 4GB swap, Docker & Compose, networks, and fail2ban) with:
```bash
git clone git@github.com:tek2991/Server-Docker-Setup.git /opt/sites
cd /opt/sites
./scripts/setup-host.sh
newgrp docker
```

---

### 1.2 Manual Setup (Step-by-Step)

#### A. OCI Local iptables (Ports 80 & 443)
OCI Ubuntu images drop traffic on ports 80 and 443 by default in iptables, regardless of your OCI Cloud Security List. Open them locally:
```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

#### B. Swap Safety Net (4GB)
Run once on the host VM to safeguard against OOM during heavy migrations or traffic spikes:
```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

#### C. Create Shared Docker Networks
```bash
docker network create web
docker network create internal
```

---

## 2. Build the Shared PHP Base Image

The shared base image packages PHP 8.3-FPM, Composer 2, and all required extensions (`intl` for Filament 5, `exif` for Spatie Media Library, `redis` for cache/sessions, `pdo_mysql`, `gd`, `zip`, `opcache`, `bcmath`):

```bash
cd shared-php
docker build -t sites-infra/shared-php-base:latest .
```

---

## 3. Configure and Start Shared Services (MariaDB + Redis)

1. Create the database root password file:
   ```bash
   cd ../shared/secrets
   cp db_root_password.txt.example db_root_password.txt
   # Edit db_root_password.txt and set a strong secret password
   ```

2. Review `shared/init/01-create-dbs.sql` and update default passwords for each site user (`dwelly`, `site_b`, `site_c`, `site_d`).

3. Start MariaDB and Redis:
   ```bash
   cd ../
   docker compose up -d
   ```

4. Verify database health:
   ```bash
   docker compose ps
   docker exec -it shared-mariadb mariadb -u root -p"$(cat secrets/db_root_password.txt)" -e "SHOW DATABASES;"
   ```

---

## 4. Deploy Applications (Example: Dwelly)

1. Clone the application repository into `dwelly/src`:
   ```bash
   cd ../dwelly
   git clone git@github.com:your-org/dwelly.git src
   ```

2. Configure environment:
   ```bash
   cp .env.example .env
   # Edit .env and set APP_KEY, DB_PASSWORD, APP_URL, etc.
   ```

3. Run deployment script:
   ```bash
   ./deploy.sh
   ```
   *The script automatically:*
   - Pulls code updates.
   - Builds the application container (compiling Vite & Tailwind assets inside the multi-stage build).
   - Syncs compiled frontend assets (`public/build`) to the host so Caddy can serve them directly.
   - Runs `php artisan migrate --force`.
   - Generates the `storage:link` symlink.
   - Optimizes Laravel config, route, view, and Filament component caches.
   - Launches the container.

---

## 5. Configure and Start Caddy Reverse Proxy

1. Review `proxy/Caddyfile`:
   - Replace `dwelly.internal.example.com` and other domains with your actual internal hostnames.
2. Start Caddy:
   ```bash
   cd ../proxy
   docker compose up -d
   ```
3. Caddy will automatically route requests for PHP to each app container via FastCGI on port 9000, while serving CSS, JS, Vite bundles, and uploaded media directly from host disk with Gzip and Zstandard compression.

---

## 6. Shared Scheduler Management

You have two choices for executing the scheduled artisan commands:

### Option A: Shared Docker Container (Default)
The `shared-scheduler` container in `shared/docker-compose.yml` iterates through each app directory every 60 seconds:
```bash
docker compose logs -f scheduler
```

### Option B: Host Crontab via `docker exec` (Recommended: 0 MB Extra RAM)
If you prefer not to keep an extra container running, stop the scheduler service (`docker compose stop scheduler`) and add this to the host server's crontab (`crontab -e`):
```cron
* * * * * docker exec -t dwelly-app php artisan schedule:run >> /var/log/dwelly-schedule.log 2>&1
* * * * * docker exec -t site-b-app php artisan schedule:run >> /var/log/site-b-schedule.log 2>&1
* * * * * docker exec -t site-c-app php artisan schedule:run >> /var/log/site-c-schedule.log 2>&1
* * * * * docker exec -t site-d-app php artisan schedule:run >> /var/log/site-d-schedule.log 2>&1
```

---

## 7. Automated Nightly Database Backups

Create a backup script at `/opt/scripts/backup-dbs.sh`:
```bash
#!/bin/bash
set -e
BACKUP_DIR="/opt/backups"
TIMESTAMP=$(date +%F_%H%M%S)
ROOT_PASS=$(cat /path/to/server-docker-setup/shared/secrets/db_root_password.txt)

mkdir -p "$BACKUP_DIR"

for db in dwelly site_b site_c site_d; do
    docker exec shared-mariadb mariadbdump -u root -p"$ROOT_PASS" "$db" | gzip > "$BACKUP_DIR/${db}_${TIMESTAMP}.sql.gz"
done

# Keep only last 14 days of backups
find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +14 -delete
```
Add to `crontab -e`:
```cron
0 2 * * * /opt/scripts/backup-dbs.sh > /dev/null 2>&1
```

---

## 8. Resource Monitoring

Check live container CPU and RAM usage:
```bash
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
```
The baseline memory consumption of all 4 idle apps, MariaDB, Redis, and Caddy sits at **~2GB**, leaving **~10GB of headroom** on the 12GB instance to comfortably absorb 200 concurrent connections and worker spikes.

---

## 9. High-Concurrency (200 Connections) & 20MB Upload Calibration

The stack is calibrated for up to 200 concurrent connections and 20MB file uploads across the proxy, database, and PHP application runtimes:

1. **MariaDB (`shared/docker-compose.yml`)**:
   - `--max-connections=250`: Accommodates 200+ concurrent connections without connection pool exhaustion.
   - `--innodb-buffer-pool-size=512M`: Expands active working set memory to keep queries fast and disk I/O low.
   - `--table-open-cache=1000` and `--thread-cache-size=32`: Minimizes thread creation overhead.
   - `--wait-timeout=300`: Reclaims idle connections after 5 minutes.
   - Container limits: `1.5G RAM / 0.5 CPU`.

2. **Web Server & Reverse Proxy (Caddy)**:
   - `request_body { max_size 30MB }`: Calibrated for 20MB uploads with multipart boundary and header margin.
   - Resource limits: `256M RAM / 0.2 CPU` to comfortably stream concurrent large file uploads and process simultaneous TLS handshakes.

3. **PHP Application Containers (`docker/php-fpm.conf`)**:
   - `pm = ondemand`: Idle memory remains minimal (~30MB per container).
   - `pm.max_children = 25`: Spawns up to 25 worker processes during traffic surges, automatically terminating them after 30s of inactivity.
   - `listen.backlog = 511`: Buffers incoming requests without dropping sockets.
   - `upload_max_filesize = 25M` & `post_max_size = 30M`: Perfectly fits 20MB uploads.
   - `max_execution_time = 120` & `max_input_time = 120`: Accommodates upload transfer times over standard connections.
   - Container limits: `1G RAM / 0.5 CPU` per app.
