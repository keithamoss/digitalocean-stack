#!/bin/bash

# Unpublishes demsausage staging config from nginx and reloads nginx
set -euo pipefail

echo "==> Checking privileges"
if [ "$EUID" -eq 0 ]; then
    echo "This script should not be run as root/sudo. Run as a regular user with docker group access." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../..")"
CONF_DEST="$ROOT_DIR/nginx/conf.d/demsausage"
NGINX_SCRIPT="$ROOT_DIR/orchestration/nginx.sh"

if [ ! -x "$NGINX_SCRIPT" ]; then
    echo "Nginx orchestrator missing or not executable: $NGINX_SCRIPT" >&2
    exit 1
fi

if [ ! -d "$(dirname "$CONF_DEST")" ]; then
    echo "Nginx conf.d directory missing: $(dirname "$CONF_DEST")" >&2
    exit 1
fi

RELOAD=0

if [ -d "$CONF_DEST" ]; then
    echo "Removing published config directory at $CONF_DEST"
    rm -rf "$CONF_DEST"
    RELOAD=1
elif [ -e "$CONF_DEST" ] || [ -L "$CONF_DEST" ]; then
    echo "Refusing to remove non-directory path: $CONF_DEST" >&2
    exit 1
else
    echo "Config not published: $CONF_DEST"
fi

if [ "$RELOAD" -eq 1 ]; then
    echo "Reloading nginx via $NGINX_SCRIPT"
    echo
    "$NGINX_SCRIPT" --skip-download
else
    echo "No changes detected; nginx reload skipped."
fi

