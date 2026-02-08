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

# Determine script and backup directories using realpath (Issue 4)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")" 
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$BACKUPS_DIR/..")"

# Load centralized configuration (Issue 3)
source "${BACKUPS_DIR}/config.sh"

# error
#
# Logs an error message to stderr and exits
#
# Arguments:
#   $* - Error message
error() {
    echo "ERROR: $*" >&2
    exit 1
}

# Source AWS credentials
[[ -f "$BACKUPS_DIR/secrets/aws.env" ]] || error "AWS credentials file not found: $BACKUPS_DIR/secrets/aws.env"
source "$BACKUPS_DIR/secrets/aws.env"

# Set restic password
[[ -f "$BACKUPS_DIR/secrets/restic.key" ]] || error "Restic password file not found: $BACKUPS_DIR/secrets/restic.key"
export RESTIC_PASSWORD=$(cat "$BACKUPS_DIR/secrets/restic.key")

# Configuration - use centralized repo from config.sh (Issue 3, 8)
RESTIC_REPO="$FOUNDRY_RESTIC_REPO"
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
    [[ -d "$path" ]] || error "Backup path does not exist: $path"
done

# Issue 7: Verify restic repository is initialized
echo "Verifying restic repository..."
if ! restic -r "$RESTIC_REPO" snapshots --last 2>/dev/null >/dev/null; then
    error "Restic repository not initialized or not accessible. Run init-foundry-backup.sh first."
fi
echo "✓ Repository verified"
echo ""

# Issue 10: Test S3 bucket accessibility before starting backup
echo "Testing S3 bucket accessibility..."
if ! restic -r "$RESTIC_REPO" stats --mode raw-data 2>/dev/null >/dev/null; then
    # S3_BUCKET comes from aws.env, AWS_DEFAULT_REGION too
    error "Cannot access S3 bucket or repository. Check AWS credentials and bucket permissions (Region: ${AWS_DEFAULT_REGION:-unknown})"
fi
echo "✓ S3 bucket accessible"
echo ""

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
    
    # Apply retention policy from centralized config (Issue 3, 17)
    # IMPORTANT: If you change these values, also update backups/config.sh
    #   FOUNDRY_RETENTION_DAILY and FOUNDRY_RETENTION_MONTHLY constants
    echo ""
    echo "Applying retention policy (${FOUNDRY_RETENTION_DAILY} daily, ${FOUNDRY_RETENTION_MONTHLY} monthly)..."
    restic -r "$RESTIC_REPO" forget \
        --tag foundry \
        --keep-daily "$FOUNDRY_RETENTION_DAILY" \
        --keep-monthly "$FOUNDRY_RETENTION_MONTHLY" \
        --prune
    
    echo ""
    echo "Repository statistics:"
    restic -r "$RESTIC_REPO" stats --json | \
        jq -r '"  Total size: \((.total_size // 0) / 1024 / 1024 | floor)MB\n  Total blob count: \(.total_blob_count // 0)"'
    
    echo ""
    echo "=========================================="
    echo "✓ Foundry backup completed successfully!"
    echo "=========================================="
    exit 0
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo ""
    echo "✗ Backup failed after ${DURATION}s"
    echo "=========================================="
    exit 1
fi
