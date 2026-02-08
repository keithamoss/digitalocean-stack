#!/bin/bash
set -euo pipefail

# Deploy all logrotate configs from infra/logrotate.d/ to /etc/logrotate.d/
# Usage: sudo ./infra/logrotate.d/deploy-logrotate.sh

SRC_DIR="$(dirname "$0")"
DEST_DIR="/etc/logrotate.d"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)." >&2
    exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
    echo "Source directory $SRC_DIR does not exist!" >&2
    exit 1
fi

for config in "$SRC_DIR"/*; do
    [ -f "$config" ] || continue
    name="digitalocean-stack-$(basename "$config")"
    cp "$config" "$DEST_DIR/$name"
    chmod 644 "$DEST_DIR/$name"
    echo "✓ Installed $DEST_DIR/$name"
done

echo "All logrotate configs deployed."
