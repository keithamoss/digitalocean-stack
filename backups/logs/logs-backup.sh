#!/bin/bash
#
# Logs Backup Script
# Syncs all log directories to S3 using aws s3 sync
# Retention: Files uploaded to S3 stay forever (aws s3 sync never deletes by default)
#
# Log directories synced:
#   - logs/nginx/               (nginx logs with logrotate)
#   - logs/backups/             (backup job logs from wrapper scripts)
#   - logs/db/                  (PostgreSQL logs)
#   - logs/docker/              (exported Docker logs)
#   - logs/demsausage-staging/  (demsausage application logs)
#
# Requirements:
# - aws CLI v2 installed (via infra/setup.sh)
# - AWS credentials in backups/secrets/aws.env
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

# Check dependencies
command -v aws >/dev/null 2>&1 || error "aws CLI is not installed. Run: sudo $REPO_ROOT/infra/setup.sh"

# Source AWS credentials
[[ -f "$BACKUPS_DIR/secrets/aws.env" ]] || error "AWS credentials file not found: $BACKUPS_DIR/secrets/aws.env"
source "$BACKUPS_DIR/secrets/aws.env"

S3_DESTINATION="$LOGS_S3_PATH"
LOGS_DIR="$REPO_ROOT/logs"

echo "=========================================="
echo "Logs Backup - $(date)"
echo "=========================================="
echo "Destination: $S3_DESTINATION"
echo "Source path: $LOGS_DIR"
echo ""

# Verify logs directory exists
[[ -d "$LOGS_DIR" ]] || error "Logs directory does not exist: $LOGS_DIR"

# List subdirectories that will be synced
echo "Log directories to be synced:"
for subdir in "$LOGS_DIR"/*/; do
    if [[ -d "$subdir" ]]; then
        dir_size=$(du -sh "$subdir" 2>/dev/null | cut -f1 || echo "unknown")
        echo "  - ${subdir} (${dir_size})"
    fi
done
echo ""

# Test S3 accessibility before starting
echo "Testing S3 bucket accessibility..."
if ! aws s3 ls "$S3_DESTINATION/" >/dev/null 2>&1; then
    error "Cannot access S3 path $S3_DESTINATION. Check AWS credentials and bucket permissions."
fi
echo "✓ S3 bucket accessible"
echo ""

# Run sync
echo "Starting sync..."
START_TIME=$(date +%s)

if aws s3 sync "$LOGS_DIR" "$S3_DESTINATION/"; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "Sync completed successfully in ${DURATION}s"

    # Write .last-sync sentinel to S3 so the monitor can detect staleness
    SYNC_TIME=$(date -Iseconds)
    echo "${SYNC_TIME} $(hostname)" | aws s3 cp - "${S3_DESTINATION}/.last-sync"
    echo "✓ Wrote .last-sync sentinel: ${SYNC_TIME}"

    # Show repository statistics
    echo ""
    echo "Repository statistics:"
    S3_SUMMARY=$(aws s3 ls --recursive --summarize "${S3_DESTINATION}/" 2>/dev/null | tail -3 || echo "")
    S3_FILES=$(echo "$S3_SUMMARY" | awk '/Total Objects:/ {print $NF}')
    S3_SIZE=$(echo "$S3_SUMMARY" | awk '/Total Size:/ {print $NF}')
    if [[ -n "$S3_FILES" ]] && [[ -n "$S3_SIZE" ]]; then
        S3_SIZE_MB=$(( (S3_SIZE + 524288) / 1048576 ))
        echo "  Total files in S3: ${S3_FILES}"
        echo "  Total S3 size:     ${S3_SIZE_MB}MB"
    fi

    echo ""
    echo "Retention policy: Files uploaded to S3 are never deleted (aws s3 sync default)"

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
