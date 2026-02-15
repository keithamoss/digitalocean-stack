#!/bin/bash
# Backup Heartbeat Wrapper
# Logs to both systemd journal (stdout/stderr) and file
# Part of Phase 3 Chunk 1: Backup Infrastructure Setup

set -euo pipefail

# Determine script and backup directories using realpath (Issue 4)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/../..")"
STACK_DIR="$(realpath "$BACKUPS_DIR/..")"

# Load shared wrapper library (Issue 1)
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging infrastructure (config.sh is loaded by setup_wrapper)
LOG_DIR="$STACK_DIR/logs/backups/heartbeat"
setup_wrapper "$LOG_DIR" "heartbeat"

# Install timeout trap handler
install_timeout_trap

# Locate heartbeat script
HEARTBEAT_SCRIPT="$SCRIPT_DIR/../scripts/backup-status.sh"

# Start logging
log "=== Backup Heartbeat Check Started ==="
log "Log file: $LOG_FILE"
log ""

# Execute heartbeat check with logging (Issue 10)
if run_with_logging "Backup Heartbeat Check" "$HEARTBEAT_SCRIPT" heartbeat; then
    exit $EXIT_SUCCESS
else
    exit $EXIT_ERROR
fi
