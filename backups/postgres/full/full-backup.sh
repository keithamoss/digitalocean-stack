#!/bin/bash
# PostgreSQL Full Backup Wrapper
# Logs to both systemd journal (stdout/stderr) and file
# Part of Phase 3 Chunk 1: Backup Infrastructure Setup

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STACK_DIR="$(dirname "$BACKUPS_DIR")"
LOG_DIR="$BACKUPS_DIR/logs/postgres"
LOG_FILE="$LOG_DIR/full-backup-$(date +%Y-%m-%d).log"
BACKUP_TYPE="full"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Function to log to both journal and file
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Start logging
log "=== PostgreSQL Full Backup Started ==="
log "Log file: $LOG_FILE"

# Run the backup
log "Executing: docker exec db /usr/local/bin/pgbackrest-wrapper --stanza=main --type=$BACKUP_TYPE backup"
if docker exec db /usr/local/bin/pgbackrest-wrapper --stanza=main --type="$BACKUP_TYPE" backup 2>&1 | tee -a "$LOG_FILE"; then
    EXIT_CODE=0
    log "=== PostgreSQL Full Backup COMPLETED SUCCESSFULLY ==="
else
    EXIT_CODE=$?
    log "=== PostgreSQL Full Backup FAILED with exit code $EXIT_CODE ==="
fi

exit $EXIT_CODE
