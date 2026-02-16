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
    basename="$(basename "$config")"
    
    # Skip non-config files
    [[ "$basename" == *.sh ]] && continue
    [[ "$basename" == *.md ]] && continue
    [[ "$basename" == *.override ]] && continue  # Skip systemd overrides (handled separately)
    
    name="digitalocean-stack-$basename"
    cp "$config" "$DEST_DIR/$name"
    chmod 644 "$DEST_DIR/$name"
    echo "✓ Installed $DEST_DIR/$name"
done

# Install logrotate.timer systemd override
TIMER_OVERRIDE_SRC="$SRC_DIR/logrotate.timer.override"
TIMER_OVERRIDE_DIR="/etc/systemd/system/logrotate.timer.d"
TIMER_OVERRIDE_DEST="$TIMER_OVERRIDE_DIR/override.conf"

if [ -f "$TIMER_OVERRIDE_SRC" ]; then
    mkdir -p "$TIMER_OVERRIDE_DIR"
    cp "$TIMER_OVERRIDE_SRC" "$TIMER_OVERRIDE_DEST"
    chmod 644 "$TIMER_OVERRIDE_DEST"
    systemctl daemon-reload
    echo "✓ Installed systemd timer override: $TIMER_OVERRIDE_DEST"
fi

echo "All logrotate configs deployed."
