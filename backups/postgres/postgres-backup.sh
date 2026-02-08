#!/bin/bash
# PostgreSQL Backup Wrapper (Unified for Full and Differential)
# Logs to both systemd journal (stdout/stderr) and file
# Part of Phase 3 Chunk 1: Backup Infrastructure Setup

set -euo pipefail

# Get backup type from first argument (default to diff)
BACKUP_TYPE="${1:-diff}"

# Validate backup type
if [[ "$BACKUP_TYPE" != "full" ]] && [[ "$BACKUP_TYPE" != "diff" ]]; then
    echo "ERROR: Invalid backup type '$BACKUP_TYPE'. Must be 'full' or 'diff'" >&2
    exit 1
fi

# Determine script and backup directories using realpath (Issue 4)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"

# Load shared wrapper library (Issue 1)
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging infrastructure (config.sh is loaded by setup_wrapper)
LOG_DIR="$BACKUPS_DIR/logs/postgres-${BACKUP_TYPE}"
setup_wrapper "$LOG_DIR" "${BACKUP_TYPE}-backup"

# Start logging
log "=== PostgreSQL ${BACKUP_TYPE^} Backup Started ==="
log "Log file: $LOG_FILE"
log "Container: $POSTGRES_DB_CONTAINER"
log "Stanza: $POSTGRES_STANZA"
log "Backup Type: $BACKUP_TYPE"
log ""

# Build backup command array (Issue 13)
BACKUP_CMD=(
    docker exec "$POSTGRES_DB_CONTAINER"
    /usr/local/bin/pgbackrest-wrapper
    --stanza="$POSTGRES_STANZA"
    --type="$BACKUP_TYPE"
    backup
)

# Execute backup with logging
if run_with_logging "PostgreSQL ${BACKUP_TYPE^} Backup" "${BACKUP_CMD[@]}"; then
    exit $EXIT_SUCCESS
else
    exit $EXIT_ERROR
fi
