#!/bin/bash
# Consolidated Backup Orchestration Runner
# Runs all backup phases in sequence

set -euo pipefail

# Determine script and backup directories using realpath
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
STACK_DIR="$(realpath "$BACKUPS_DIR/..")"

# Load shared wrapper library (also loads centralized config via setup_wrapper)
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging infrastructure
LOG_DIR="$STACK_DIR/logs/backups/consolidated"
setup_wrapper "$LOG_DIR" "run"

# Install timeout trap handler
install_timeout_trap

# Track failures by phase
declare -a FAILED_PHASES=()

run_phase() {
    local phase_name="$1"
    local service_name="$2"
    local phase_start=$(date +%s)

    log ""
    log "--- Phase: ${phase_name} ---"
    if run_with_logging "$phase_name" systemctl start "$service_name"; then
        local phase_secs=$(( $(date +%s) - phase_start ))
        log "✓ Phase succeeded: ${phase_name} (phase: $(format_duration $phase_secs))"
        return 0
    else
        local exit_code=$?
        local phase_secs=$(( $(date +%s) - phase_start ))
        log "✗ Phase failed: ${phase_name} (service: ${service_name}, exit: ${exit_code}, phase: $(format_duration $phase_secs))"
        FAILED_PHASES+=("${phase_name}")
        return 1
    fi
}

# Select PostgreSQL backup type by day (Sunday=full, otherwise differential)
POSTGRES_SERVICE="postgres-diff-backup.service"
POSTGRES_PHASE="PostgreSQL Differential Backup"
if [[ "$(date +%u)" -eq 7 ]]; then
    POSTGRES_SERVICE="postgres-full-backup.service"
    POSTGRES_PHASE="PostgreSQL Full Backup"
fi

log "=== Consolidated Backup Run Started ==="
log "Log file: $LOG_FILE"
log "Selected PostgreSQL phase: ${POSTGRES_PHASE}"
log ""
log "Execution order: PostgreSQL -> Foundry -> Docker logs export -> Logs backup -> Configs backup"

# Run all phases in sequence, continue even if one fails
run_phase "$POSTGRES_PHASE" "$POSTGRES_SERVICE" || true
run_phase "Foundry Backup" "foundry-backup.service" || true
run_phase "Docker Logs Export" "docker-logs-export.service" || true
run_phase "Logs Backup" "logs-backup.service" || true
run_phase "Operational Backup" "operational-backup.service" || true

# Final consolidated summary
log ""
if (( ${#FAILED_PHASES[@]} == 0 )); then
    log "✓ Consolidated backup run completed successfully"
    exit $EXIT_SUCCESS
fi

log "✗ Consolidated backup run completed with failures"
for phase in "${FAILED_PHASES[@]}"; do
    log "  - ${phase}"
done

exit $EXIT_ERROR
