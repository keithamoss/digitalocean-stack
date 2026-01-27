#!/bin/bash
#
# Foundry VTT Backup Script
# Backs up Foundry Data and Config directories to S3 using restic
#
# Requirements:
# - restic installed
# - AWS credentials in backups/secrets/aws.env
# - Restic password in backups/secrets/restic.key
#

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BACKUPS_DIR/.." && pwd)"

# Source AWS credentials
if [[ ! -f "$BACKUPS_DIR/secrets/aws.env" ]]; then
    echo "ERROR: AWS credentials file not found: $BACKUPS_DIR/secrets/aws.env"
    exit 1
fi
source "$BACKUPS_DIR/secrets/aws.env"

# Set restic password
if [[ ! -f "$BACKUPS_DIR/secrets/restic.key" ]]; then
    echo "ERROR: Restic password file not found: $BACKUPS_DIR/secrets/restic.key"
    exit 1
fi
export RESTIC_PASSWORD=$(cat "$BACKUPS_DIR/secrets/restic.key")

# Configuration
RESTIC_REPO="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${S3_BUCKET}/pi-hosting/foundry"
FOUNDRY_DATA_DIR="$REPO_ROOT/foundry/data"
BACKUP_PATHS=("$FOUNDRY_DATA_DIR/Data" "$FOUNDRY_DATA_DIR/Config")

# Logging - now handled by wrapper script, just output to stdout/stderr
# The foundry-backup-wrapper.sh will capture and log everything

echo "=========================================="
echo "Foundry VTT Backup - $(date)"
echo "=========================================="
echo "Repository: $RESTIC_REPO"
echo "Backup paths:"
for path in "${BACKUP_PATHS[@]}"; do
    echo "  - $path"
done
echo ""

# Verify paths exist
for path in "${BACKUP_PATHS[@]}"; do
    if [[ ! -d "$path" ]]; then
        echo "ERROR: Backup path does not exist: $path"
        exit 1
    fi
done

# Run backup
echo "Starting backup..."
START_TIME=$(date +%s)

if restic -r "$RESTIC_REPO" backup \
    --tag foundry \
    --tag daily \
    --host raspberrypi \
    "${BACKUP_PATHS[@]}"; then
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo ""
    echo "Backup completed successfully in ${DURATION}s"
    
    # Show latest snapshot info
    echo ""
    echo "Latest snapshot:"
    restic -r "$RESTIC_REPO" snapshots --latest 1 --json | \
        jq -r '.[] | "  ID: \(.short_id)\n  Time: \(.time)\n  Hostname: \(.hostname)\n  Files: \((.files_new // 0) + (.files_changed // 0) + (.files_unmodified // 0)) (\(.files_new // 0) new, \(.files_changed // 0) changed)\n  Size: \(((.size_new // 0) + (.size_changed // 0) + (.size_unmodified // 0)) / 1024 / 1024 | floor)MB (\((.size_new // 0) / 1024 / 1024 | floor)MB new)"'
    
    # Apply retention policy: keep 30 daily, then 1 monthly
    echo ""
    echo "Applying retention policy (30 daily, then monthly)..."
    restic -r "$RESTIC_REPO" forget \
        --tag foundry \
        --keep-daily 30 \
        --keep-monthly 12 \
        --prune
    
    echo ""
    echo "Repository statistics:"
    restic -r "$RESTIC_REPO" stats --json | \
        jq -r '"  Total size: \((.total_size // 0) / 1024 / 1024 | floor)MB\n  Total blob count: \(.total_blob_count // 0)"'
    
    echo ""
    echo "=========================================="
    echo "Foundry backup completed successfully!"
    echo "=========================================="
    exit 0
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo ""
    echo "ERROR: Backup failed after ${DURATION}s"
    echo "=========================================="
    exit 1
fi
