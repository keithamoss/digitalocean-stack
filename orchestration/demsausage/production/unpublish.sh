#!/bin/bash

# Unpublishes demsausage production and disables auto-redeploy.
#
# Note: The production stack uses an nginx container embedded in the compose file.
# See publish.sh for context on why this script is limited to symlink management.
set -euo pipefail

echo "==> Checking privileges"
if [ "$EUID" -eq 0 ]; then
    echo "This script should not be run as root/sudo. Run as a regular user with docker group access." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
ROOT_DIR="$(realpath "$SCRIPT_DIR/../../..")"

echo ""
echo "==> Disabling auto-redeploy target"
SYMLINK="${ROOT_DIR}/auto-redeploy/enabled/demsausage-production.conf"

if [ -L "$SYMLINK" ]; then
    rm "$SYMLINK"
    echo "Removed symlink: $SYMLINK"
    echo "Commit the removal to record the disabled state in git:"
    echo "  git add auto-redeploy/enabled/demsausage-production.conf && git commit -m 'Disable demsausage-production auto-redeploy'"
elif [ -e "$SYMLINK" ]; then
    echo "ERROR: $SYMLINK exists but is not a symlink" >&2
    exit 1
else
    echo "Auto-redeploy symlink not present — nothing to remove"
fi
