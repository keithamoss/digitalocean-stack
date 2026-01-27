#!/bin/bash
# Backup Heartbeat Wrapper
# Logs to both systemd journal (stdout/stderr) and file
# Part of Phase 3 Chunk 1: Backup Infrastructure Setup

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="$BACKUPS_DIR/logs/heartbeat"
LOG_FILE="$LOG_DIR/heartbeat-$(date +%Y-%m-%d).log"
HEARTBEAT_SCRIPT="$SCRIPT_DIR/../scripts/backup-status.sh"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Function to log to both journal and file
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Start logging
log "=== Backup Heartbeat Check Started ==="
log "Log file: $LOG_FILE"

# Run the heartbeat check
log "Executing: $HEARTBEAT_SCRIPT heartbeat"
if "$HEARTBEAT_SCRIPT" heartbeat 2>&1 | tee -a "$LOG_FILE"; then
    EXIT_CODE=0
    log "=== Backup Heartbeat Check COMPLETED SUCCESSFULLY ==="
else
    EXIT_CODE=$?
    log "=== Backup Heartbeat Check FAILED with exit code $EXIT_CODE ==="
fi

exit $EXIT_CODE
