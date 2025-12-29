#!/bin/bash

# Publishes demsausage staging config to nginx and reloads nginx
set -euo pipefail

echo "==> Checking privileges"
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo/root." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../..")"
CONF_SRC="$ROOT_DIR/demsausage/nginx/conf.d"
CONF_DEST="$ROOT_DIR/nginx/conf.d/demsausage"
NGINX_SCRIPT="$ROOT_DIR/orchestration/nginx.sh"

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

RELOAD=0

if [ -L "$CONF_DEST" ]; then
    current_target="$(readlink "$CONF_DEST")"
    if [ "$current_target" != "$CONF_SRC" ]; then
        echo "Existing symlink target mismatch: $current_target (expected $CONF_SRC). Refusing to change." >&2
        exit 1
    fi

    echo "Config already published (symlink in place); skipping reload."
    exit 0
elif [ -e "$CONF_DEST" ]; then
    echo "Refusing to overwrite non-symlink path: $CONF_DEST" >&2
    exit 1
else
    ln -s "$CONF_SRC" "$CONF_DEST"
    echo "Published symlink: $CONF_DEST -> $CONF_SRC"
    RELOAD=1
fi

if [ "$RELOAD" -eq 1 ]; then
    echo "Reloading nginx via $NGINX_SCRIPT"
    echo
    "$NGINX_SCRIPT"
else
    echo "No changes detected; nginx reload skipped."
fi
