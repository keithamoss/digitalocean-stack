#!/bin/bash
# Foundry VTT Backup Wrapper
# Logs to both systemd journal (stdout/stderr) and file
# Part of Phase 3 Chunk 1: Backup Infrastructure Setup

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$BACKUPS_DIR/logs/foundry"
LOG_FILE="$LOG_DIR/backup-$(date +%Y-%m-%d).log"
FOUNDRY_BACKUP_SCRIPT="$SCRIPT_DIR/foundry-backup.sh"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Function to log to both journal and file
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Start logging
log "=== Foundry VTT Backup Started ==="
log "Log file: $LOG_FILE"

# Run the actual backup script
log "Executing: $FOUNDRY_BACKUP_SCRIPT"
if "$FOUNDRY_BACKUP_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
    EXIT_CODE=0
    log "=== Foundry VTT Backup COMPLETED SUCCESSFULLY ==="
else
    EXIT_CODE=$?
    log "=== Foundry VTT Backup FAILED with exit code $EXIT_CODE ==="
fi

exit $EXIT_CODE
