#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "========================================="
echo " Deploying Site C Application"
echo "========================================="

if [ -d "src/.git" ]; then
    echo "Pulling latest code from git repository..."
    git -C src pull origin main
fi

echo "Building app container image..."
docker compose build app

echo "Syncing frontend assets to host for Caddy proxy..."
temp_container=$(docker compose create app)
docker cp "$temp_container:/var/www/html/public/build" src/public/ 2>/dev/null || true
docker rm -v "$temp_container" >/dev/null 2>&1

echo "Running database migrations..."
docker compose run --rm app php artisan migrate --force

echo "Creating storage symlink..."
docker compose run --rm app php artisan storage:link --quiet || true

echo "Optimizing route, config, and view caches..."
docker compose run --rm app php artisan config:cache
docker compose run --rm app php artisan route:cache
docker compose run --rm app php artisan view:cache

echo "Starting updated application container..."
docker compose up -d

echo "========================================="
echo " Site C successfully deployed!"
echo "========================================="
