#!/bin/bash
#
# Export Docker logs for services without file-based logging
# Only exports: Redis, memcached, rq_dashboard, cloudflared tunnels, Foundry
# Skips: nginx, demsausage, PostgreSQL (already have file-based logs)
#
# Run daily at 00:02 via systemd timer (before logrotate at 00:15)
# Writes to static filenames - logrotate handles rotation/compression/retention
#

set -euo pipefail

# Configuration
LOG_DIR="/home/keith/digitalocean-stack/logs/docker"
# Precise date range: yesterday midnight to midnight
SINCE_DATE=$(date -d 'yesterday' +%Y-%m-%d)T00:00:00
UNTIL_DATE=$(date -d 'yesterday' +%Y-%m-%d)T23:59:59

# Services to export (NO file-based logging)
SERVICES_TO_EXPORT=(
    "redis"
    "demsausage-memcached-1"
    "demsausage-rq_dashboard-1"
    "pi-hosting-cloudflared-demsausage-org-1"
    "pi-hosting-cloudflared-keithmoss-me-1"
    "foundry-foundry-1"
)

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

echo "=== Docker Log Export Started at $(date) ==="
echo "Exporting logs for services without file-based logging only"

# Export logs for each service
for service in "${SERVICES_TO_EXPORT[@]}"; do
    # Check if container exists and is running
    if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
        # Write to flat directory structure - logrotate will rotate at midnight
        log_file="$LOG_DIR/${service}.log"
        
        echo "Exporting logs for $service..."
        
        # Export logs with precise date range (yesterday midnight to midnight)
        # Overwrite the file (it was already rotated by logrotate at 00:00)
        docker logs --since "$SINCE_DATE" --until "$UNTIL_DATE" "$service" > "$log_file" 2>&1 || {
            echo "WARNING: Failed to export logs for $service"
            continue
        }
        
        # Get log size
        log_size=$(du -h "$log_file" | cut -f1)
        echo "  → Exported to $log_file ($log_size)"
    else
        echo "WARNING: Container $service not found or not running, skipping"
    fi
done

echo "=== Docker Log Export Completed at $(date) ==="
echo ""

# Summary
echo "Summary:"
echo "  Total services exported: ${#SERVICES_TO_EXPORT[@]}"
echo "  Log directory: $LOG_DIR"
echo "  Rotation/compression/retention: Managed by logrotate (runs at 00:00)"
echo "  Note: nginx, demsausage, and PostgreSQL logs are already captured via volume mounts"
echo ""

exit 0
