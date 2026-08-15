#!/bin/bash

# Deploy demsausage staging — pulls new images, restarts containers, purges Cloudflare cache.
# Extracted from orchestration/demsausage-staging.sh; replaces the legacy redeploy script.
# Can be run manually for ad-hoc deploys; also serves as the reference for auto-redeploy.sh
# inline deploy logic.
set -euo pipefail

echo "==> Checking privileges"
if [ "$EUID" -eq 0 ]; then
    echo "This script should not be run as root/sudo. Run as a regular user with docker group access." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../..")"
COMPOSE_FILE="${ROOT_DIR}/demsausage/staging.yml"
CLOUDFLARE_ENV="${ROOT_DIR}/orchestration/secrets/cloudflare.env"
NGINX_SCRIPT="${ROOT_DIR}/orchestration/nginx.sh"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Compose file not found: $COMPOSE_FILE" >&2
    exit 1
fi

echo "==> Pulling latest images..."
docker compose -f "$COMPOSE_FILE" pull

echo "==> Stopping existing containers..."
docker compose -f "$COMPOSE_FILE" stop

echo "==> Starting updated containers..."
docker compose -f "$COMPOSE_FILE" up --remove-orphans --wait --wait-timeout 60 -d

echo "==> Reloading nginx to refresh upstream DNS mappings..."
if [ ! -x "$NGINX_SCRIPT" ]; then
    echo "ERROR: nginx orchestration script not found or not executable: $NGINX_SCRIPT" >&2
    exit 1
fi
if ! "$NGINX_SCRIPT" --skip-download; then
    echo "ERROR: nginx refresh failed via $NGINX_SCRIPT" >&2
    exit 1
fi

echo "==> Pruning old images..."
docker image prune --force

echo "==> Purging Cloudflare cache..."
if [ -f "$CLOUDFLARE_ENV" ]; then
    # shellcheck source=/dev/null
    source "$CLOUDFLARE_ENV"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
        -H "X-Auth-Email: ${CF_EMAIL}" \
        -H "X-Auth-Key: ${CF_API_KEY}" \
        -H "Content-Type: application/json" \
        --data '{"purge_everything":true}'
    echo ""
else
    echo "WARNING: Cloudflare env not found: ${CLOUDFLARE_ENV} — skipping purge"
fi

echo "==> Deployment complete"
