#!/bin/bash

# Publishes demsausage staging config to nginx and reloads nginx
set -euo pipefail

echo "==> Checking privileges"
if [ "$EUID" -eq 0 ]; then
    echo "This script should not be run as root/sudo. Run as a regular user with docker group access." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../..")"
CERT_CONF="$SCRIPT_DIR/cert.conf"
CONF_SRC="$ROOT_DIR/demsausage/nginx/conf.d"
CONF_DEST="$ROOT_DIR/nginx/conf.d/demsausage"
NGINX_SCRIPT="$ROOT_DIR/orchestration/nginx.sh"
CERT_DIR="$ROOT_DIR/nginx/certs"

if [ ! -f "$CERT_CONF" ]; then
    echo "Certificate configuration not found: $CERT_CONF" >&2
    exit 1
fi

if [ ! -d "$CONF_SRC" ]; then
    echo "Config source directory not found: $CONF_SRC" >&2
    exit 1
fi

if [ ! -x "$NGINX_SCRIPT" ]; then
    echo "Nginx orchestrator missing or not executable: $NGINX_SCRIPT" >&2
    exit 1
fi

if [ ! -d "$(dirname "$CONF_DEST")" ]; then
    echo "Nginx conf.d directory missing: $(dirname "$CONF_DEST")" >&2
    exit 1
fi

echo "==> Loading certificate configuration"
source "$CERT_CONF"

DOMAIN_ARGS=""
for domain in "${CERT_DOMAINS[@]}"; do
    DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
done

if [ -f "$ROOT_DIR/orchestration/secrets/cloudflare.env" ]; then
    source "$ROOT_DIR/orchestration/secrets/cloudflare.env"
fi

if [ -z "${CF_TOKEN:-}" ]; then
    echo "CF_TOKEN not set in orchestration/secrets/cloudflare.env" >&2
    exit 1
fi

echo ""
echo "==> Ensuring certificate for $CERT_PRIMARY_DOMAIN"
RELOAD_NEEDED=0
set +e  # Temporarily disable exit on error for acme.sh
CF_Token=$CF_TOKEN ~/.acme.sh/acme.sh --issue --dns dns_cf --server letsencrypt $DOMAIN_ARGS \
    --keylength ec-256
ISSUE_EXIT=$?
set -e  # Re-enable exit on error

if [ $ISSUE_EXIT -eq 0 ]; then
    echo "==> New certificate issued successfully"
    INSTALL_NEEDED=1
elif [ $ISSUE_EXIT -eq 2 ]; then
    echo "==> Certificate already exists and is valid, checking if installation needed"
    # Check if cert files exist in nginx
    if [ ! -f "$CERT_DIR/${CERT_NAME}.key" ] || [ ! -f "$CERT_DIR/${CERT_NAME}.fullchain.pem" ]; then
        echo "==> Certificate files missing from nginx, installing"
        INSTALL_NEEDED=1
    else
        echo "==> Certificate files already installed"
        INSTALL_NEEDED=0
    fi
else
    echo "ERROR: Failed to issue certificate (exit code: $ISSUE_EXIT)" >&2
    echo "Run with --debug flag or check acme.sh logs for details" >&2
    exit 1
fi

if [ $INSTALL_NEEDED -eq 1 ]; then
    echo "==> Installing certificate to nginx"
    CF_Token=$CF_TOKEN ~/.acme.sh/acme.sh --install-cert -d "$CERT_PRIMARY_DOMAIN" --ecc \
        --key-file "$CERT_DIR/${CERT_NAME}.key" \
        --fullchain-file "$CERT_DIR/${CERT_NAME}.fullchain.pem" \
        --reloadcmd "$NGINX_SCRIPT --skip-download"
    RELOAD_NEEDED=1
fi

echo ""
echo "==> Syncing configs to nginx workspace"
if [ -e "$CONF_DEST" ] && [ ! -d "$CONF_DEST" ]; then
    echo "Refusing to overwrite non-directory path: $CONF_DEST" >&2
    exit 1
fi

mkdir -p "$CONF_DEST"

rsync_output="$(rsync -a --delete --out-format='%n%L' "$CONF_SRC"/ "$CONF_DEST"/)"

if [ -n "$rsync_output" ]; then
    echo "$rsync_output"
    RELOAD_NEEDED=1
else
    echo "No config changes detected"
fi

echo ""
if [ $RELOAD_NEEDED -eq 1 ]; then
    echo "==> Reloading nginx"
    "$NGINX_SCRIPT"
else
    echo "No changes detected; nginx reload skipped"
fi
