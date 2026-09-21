#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "========================================="
echo " Deploying SITE-B Application"
echo "========================================="

if [ -d "src/.git" ]; then
    echo "Pulling latest code from git repository..."
    git -C src pull origin main
fi

echo "Building app container image..."
docker compose build app

echo "Running database migrations..."
docker compose run --rm app php artisan migrate --force

echo "Starting updated application container..."
docker compose up -d

echo "Publishing frontend assets..."
docker compose exec app php artisan storage:link --quiet || true
docker compose exec app php artisan filament:assets 2>/dev/null || true

echo "Syncing frontend assets to host for Caddy proxy..."
docker cp site-b-app:/var/www/html/public/. src/public/
chmod -R a+rX src/public/

echo "Optimizing route, config, and view caches..."
docker compose exec app php artisan optimize:clear 2>/dev/null || true
docker compose exec app php artisan config:cache
docker compose exec app php artisan route:cache
docker compose exec app php artisan view:cache

echo "========================================="
echo " SITE-B successfully deployed!"
echo "========================================="
