#!/bin/bash

# Unpublishes demsausage staging config from nginx and reloads nginx
set -euo pipefail

echo "==> Checking privileges"
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo/root." >&2
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

if [ -L "$CONF_DEST" ]; then
    target="$(readlink "$CONF_DEST")"
    if [ -z "$target" ]; then
        echo "Symlink exists but target is empty: $CONF_DEST" >&2
        exit 1
    fi
    if [ ! -e "$target" ]; then
        echo "Symlink target missing: $target (from $CONF_DEST)" >&2
        exit 1
    fi

    rm "$CONF_DEST"
    echo "Removed symlink: $CONF_DEST (target: $target)"
    RELOAD=1
elif [ -d "$CONF_DEST" ]; then
    echo "Refusing to remove directory at $CONF_DEST (expected symlink)." >&2
    exit 1
elif [ -e "$CONF_DEST" ]; then
    echo "Refusing to remove non-symlink path: $CONF_DEST" >&2
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

