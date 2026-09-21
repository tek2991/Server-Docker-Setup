#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "========================================="
echo " Deploying Dwelly Application"
echo "========================================="

# 1. Pull latest code if git repo is initialized
if [ -d "src/.git" ]; then
    echo "Pulling latest code from git repository..."
    git -C src pull origin main
fi

# 2. Build production Docker image
echo "Building app container image..."
docker compose build app



# 4. Run Laravel migrations and caches
echo "Running database migrations..."
docker compose run --rm app php artisan migrate --force

echo "Creating storage symlink..."
docker compose run --rm app php artisan storage:link --quiet || true

echo "Optimizing route, config, and view caches..."
docker compose run --rm app php artisan config:cache
docker compose run --rm app php artisan route:cache
docker compose run --rm app php artisan view:cache

echo "Optimizing Filament components and icons..."
docker compose run --rm app php artisan filament:optimize || true

# 5. Bring up container
echo "Starting updated application container..."
docker compose up -d

# 6. Export compiled frontend assets to host so Caddy can serve them directly
echo "Syncing frontend assets to host for Caddy proxy..."
docker cp $(docker compose ps -q app):/var/www/html/public/build src/public/ 2>/dev/null || true

echo "========================================="
echo " Dwelly successfully deployed!"
echo "========================================="
