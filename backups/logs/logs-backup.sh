#!/bin/bash
#
# Logs Backup Script
# Backs up all log directories to S3 using restic
# Retention: Keep all snapshots forever (no forget policy)
#
# Log directories backed up:
#   - logs/nginx/       (nginx logs with logrotate)
#   - logs/backups/     (backup job logs from wrapper scripts)
#   - logs/db/          (PostgreSQL logs)
#   - logs/docker/      (exported Docker logs)
#   - logs/demsausage-staging/  (demsausage application logs)
#
# Requirements:
# - restic installed
# - AWS credentials in backups/secrets/aws.env
# - Restic password in backups/secrets/restic.key
#

set -euo pipefail

# Determine script and backup directories using realpath
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$BACKUPS_DIR/..")"

# Load centralized configuration
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

# Configuration - use centralized repo from config.sh
RESTIC_REPO="$LOGS_RESTIC_REPO"
LOGS_DIR="$REPO_ROOT/logs"

echo "=========================================="
echo "Logs Backup - $(date)"
echo "=========================================="
echo "Repository: $RESTIC_REPO"
echo "Backup path: $LOGS_DIR"
echo ""

# Verify logs directory exists
[[ -d "$LOGS_DIR" ]] || error "Logs directory does not exist: $LOGS_DIR"

# List subdirectories that will be backed up
echo "Log directories to be backed up:"
for subdir in "$LOGS_DIR"/*/; do
    if [[ -d "$subdir" ]]; then
        dir_size=$(du -sh "$subdir" 2>/dev/null | cut -f1 || echo "unknown")
        echo "  - ${subdir} (${dir_size})"
    fi
done
echo ""

# Verify restic repository is initialized
echo "Verifying restic repository..."
if ! restic -r "$RESTIC_REPO" snapshots --last 2>/dev/null >/dev/null; then
    error "Restic repository not initialized or not accessible. Run init-logs-backup.sh first."
fi
echo "✓ Repository verified"
echo ""

# Test S3 bucket accessibility before starting backup
echo "Testing S3 bucket accessibility..."
if ! restic -r "$RESTIC_REPO" stats --mode raw-data 2>/dev/null >/dev/null; then
    error "Cannot access S3 bucket or repository. Check AWS credentials and bucket permissions (Region: ${AWS_DEFAULT_REGION:-unknown})"
fi
echo "✓ S3 bucket accessible"
echo ""

# Run backup
echo "Starting backup..."
START_TIME=$(date +%s)

if restic -r "$RESTIC_REPO" backup \
    --tag logs \
    --tag daily \
    --host raspberrypi \
    --exclude="*.lock" \
    --exclude="*.tmp" \
    "$LOGS_DIR"; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "Backup completed successfully in ${DURATION}s"

    # Show latest snapshot info
    echo ""
    echo "Latest snapshot:"
    restic -r "$RESTIC_REPO" snapshots --latest 1 --json | \
        jq -r '.[] | "  ID: \(.short_id)\n  Time: \(.time)\n  Hostname: \(.hostname)\n  Files: \((.files_new // 0) + (.files_changed // 0) + (.files_unmodified // 0)) (\(.files_new // 0) new, \(.files_changed // 0) changed)\n  Size: \(((.size_new // 0) + (.size_changed // 0) + (.size_unmodified // 0)) / 1024 / 1024 | floor)MB (\((.size_new // 0) / 1024 / 1024 | floor)MB new)"'

    # Retention policy: Keep all snapshots forever (no forget/prune)
    # Logs are retained indefinitely per the backup strategy
    echo ""
    echo "Retention policy: Keep all snapshots forever (no pruning)"

    echo ""
    echo "Repository statistics:"
    restic -r "$RESTIC_REPO" stats --json | \
        jq -r '"  Total size: \((.total_size // 0) / 1024 / 1024 | floor)MB\n  Total blob count: \(.total_blob_count // 0)"'

    echo ""
    echo "=========================================="
    echo "✓ Logs backup completed successfully!"
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
