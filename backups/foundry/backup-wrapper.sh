#!/bin/bash
# Foundry VTT Backup Wrapper
# Logs to both systemd journal (stdout/stderr) and file
# Part of Phase 3 Chunk 1: Backup Infrastructure Setup

set -euo pipefail

# Determine script and backup directories using realpath (Issue 4)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"

# Load shared wrapper library (Issue 1)
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging infrastructure (config.sh is loaded by setup_wrapper)
LOG_DIR="$BACKUPS_DIR/logs/foundry"
setup_wrapper "$LOG_DIR" "backup"

# Locate backup script
FOUNDRY_BACKUP_SCRIPT="$SCRIPT_DIR/foundry-backup.sh"

# Start logging
log "=== Foundry VTT Backup Started ==="
log "Log file: $LOG_FILE"
log ""

# Execute backup with logging (Issue 10)
if run_with_logging "Foundry VTT Backup" "$FOUNDRY_BACKUP_SCRIPT"; then
    exit $EXIT_SUCCESS
else
    exit $EXIT_ERROR
fi
