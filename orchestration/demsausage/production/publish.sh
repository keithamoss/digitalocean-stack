#!/bin/bash

# Publishes demsausage production and enables auto-redeploy.
#
# Note: The production stack uses an nginx container embedded in the compose file
# (keithmoss/demsausage-nginx:latest-production) rather than the standalone nginx
# container used by staging. Certificate management and nginx vhost configuration
# are handled within the compose stack itself.
#
# This script's role is therefore limited to enabling auto-redeploy on this host.
# Extend this script with TLS/nginx steps when production migrates to standalone nginx.
set -euo pipefail

echo "==> Checking privileges"
if [ "$EUID" -eq 0 ]; then
    echo "This script should not be run as root/sudo. Run as a regular user with docker group access." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../..")"

echo ""
echo "==> Enabling auto-redeploy target"
ENABLED_DIR="${ROOT_DIR}/auto-redeploy/enabled"
SYMLINK="${ENABLED_DIR}/demsausage-production.conf"
CONF_TARGET="../../orchestration/demsausage/production/auto-redeploy.conf"

mkdir -p "$ENABLED_DIR"
if [ -L "$SYMLINK" ]; then
    echo "Auto-redeploy symlink already exists: $SYMLINK"
elif [ -e "$SYMLINK" ]; then
    echo "ERROR: $SYMLINK exists but is not a symlink" >&2
    exit 1
else
    ln -s "$CONF_TARGET" "$SYMLINK"
    echo "Created symlink: $SYMLINK -> $CONF_TARGET"
    echo "Commit the symlink to record the enabled state in git:"
    echo "  git add auto-redeploy/enabled/demsausage-production.conf && git commit -m 'Enable demsausage-production auto-redeploy'"
fi
