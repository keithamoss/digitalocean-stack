#!/bin/bash
# Operational Backup Wrapper
# Logs to both systemd journal (stdout/stderr) and file
# Part of Phase 3 Step 2: Configuration Backup (renamed to Operational Backup 2026-04-03)

set -euo pipefail

# Determine script and backup directories using realpath
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
STACK_DIR="$(realpath "$BACKUPS_DIR/..")"

# Load shared wrapper library
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging infrastructure (config.sh is loaded by setup_wrapper)
LOG_DIR="$STACK_DIR/logs/backups/operational-backup"
setup_wrapper "$LOG_DIR" "backup"

# Install timeout trap handler
install_timeout_trap

# Locate backup script
CONFIGS_BACKUP_SCRIPT="$SCRIPT_DIR/operational-backup.sh"

# Start logging
log "=== Operational Backup Started ==="
log "Log file: $LOG_FILE"
log ""

# Execute backup with logging
if run_with_logging "Configs Backup" "$CONFIGS_BACKUP_SCRIPT"; then
    exit $EXIT_SUCCESS
else
    exit $EXIT_ERROR
fi
