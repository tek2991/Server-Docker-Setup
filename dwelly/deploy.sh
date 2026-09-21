#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "========================================="
echo " Deploying Dwelly Application"
echo "========================================="

# 1. Pull latest code from git repository
if [ -d "src/.git" ]; then
    echo "Pulling latest code from git repository..."
    git -C src pull origin main
fi

# 2. Build production Docker image
echo "Building app container image..."
docker compose build app

# 3. Run database migrations
echo "Running database migrations..."
docker compose run --rm app php artisan migrate --force

# 4. Start/Restart application container
echo "Starting application container..."
docker compose up -d

# 5. Ensure storage symlink & publish Filament assets
echo "Publishing frontend assets..."
docker compose exec app php artisan storage:link --quiet || true
docker compose exec app php artisan filament:assets

# 6. Export all compiled frontend assets directly from dwelly-app to host for Caddy
echo "Syncing frontend assets to host for Caddy proxy..."
docker cp dwelly-app:/var/www/html/public/. src/public/
chmod -R a+rX src/public/

# 7. Optimize route, config, and view caches
echo "Optimizing route, config, and view caches..."
docker compose exec app php artisan optimize:clear
docker compose exec app php artisan config:cache
docker compose exec app php artisan route:cache
docker compose exec app php artisan view:cache

echo "========================================="
echo " Dwelly successfully deployed!"
echo "========================================="
