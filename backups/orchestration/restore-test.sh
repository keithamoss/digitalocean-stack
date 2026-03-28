#!/bin/bash
# Restore Test Orchestration Runner
# Phase 5: Automated Restore Testing
#
# Runs monthly integrity checks and full restore tests.
#
# Current scope:
#   Phase 5 Part 1 — integrity checks:
#     - Foundry restic repository: `restic check` (structural consistency)
#     - Configs restic repository: `restic check` (structural consistency)
#     - Logs S3 bucket: accessibility + .last-sync sentinel check
#       (Logs backup uses `aws s3 sync`, not restic — no restic repo exists)
#   Phase 5 Part 2 — PostgreSQL restore test:
#     - Restore latest pgBackRest backup to /tmp/postgres-restore-test/
#     - Start restored PostgreSQL on port 5433
#     - Validate databases, schema, PostGIS, and row counts vs. production
#     - Detailed report sent as a separate Discord message by postgres/restore-test.sh
#     - Logs: logs/restore/postgresql/
#
# Future scope:
#   - Phase 5 Part 3: Foundry restore test
#
# Schedule: Monthly on 1st Sunday at 4:00 AM (after 3:00 AM consolidated backup)
# Logs:     logs/restore/

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
STACK_DIR="$(realpath "$BACKUPS_DIR/..")"
SECRETS_DIR="${BACKUPS_DIR}/secrets"

# Load shared wrapper library (also loads config.sh via setup_wrapper)
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging to logs/restore/
LOG_DIR="$STACK_DIR/logs/restore"
setup_wrapper "$LOG_DIR" "restore-test"

# Install timeout trap handler
install_timeout_trap

# Load Discord notification library
source "${BACKUPS_DIR}/monitoring/scripts/discord-lib.sh"
DISCORD_ENV="${SECRETS_DIR}/discord.env"
if [[ -f "$DISCORD_ENV" ]]; then
    source "$DISCORD_ENV"
fi

# ─── State tracking ──────────────────────────────────────────────────────────

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=()
INTEGRITY_RESULTS=()    # Human-readable lines for Discord summary

# ─── Helpers ─────────────────────────────────────────────────────────────────

# run_integrity_check
#
# Runs a named integrity check function, tracking pass/fail state.
# Continues execution even if the check fails.
#
# Arguments:
#   $1 - Human-readable check name
#   $2 - Function to call
run_integrity_check() {
    local name="$1"
    local check_func="$2"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    log ""
    log "--- Integrity Check: ${name} ---"

    if "$check_func"; then
        log "✓ ${name}: passed"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        INTEGRITY_RESULTS+=("✅ ${name}")
    else
        log "✗ ${name}: FAILED"
        FAILED_CHECKS+=("${name}")
        INTEGRITY_RESULTS+=("❌ ${name}")
    fi
}

# check_restic_repo
#
# Runs `restic check` on a repository to verify structural integrity.
# Checks index/pack consistency without downloading blob data.
#
# Arguments:
#   $1 - Human-readable repo name (e.g., "Foundry")
#   $2 - Restic repository URL
check_restic_repo() {
    local repo_name="$1"
    local repo_url="$2"

    log "Repository: ${repo_url}"

    local check_stderr
    check_stderr=$(mktemp)

    local check_output
    if check_output=$(restic --no-cache -r "$repo_url" check 2>"$check_stderr"); then
        echo "$check_output" | tee -a "$LOG_FILE"
        rm -f "$check_stderr"
        log "✓ ${repo_name} repository is consistent"
        return 0
    else
        local exit_code=$?
        echo "$check_output" | tee -a "$LOG_FILE"
        cat "$check_stderr" | tee -a "$LOG_FILE"
        rm -f "$check_stderr"
        log "✗ ${repo_name} restic check failed (exit code: ${exit_code})"
        return 1
    fi
}

# ─── Integrity check functions ───────────────────────────────────────────────

check_foundry_integrity() {
    check_restic_repo "Foundry" "$FOUNDRY_RESTIC_REPO"
}

check_configs_integrity() {
    check_restic_repo "Configs" "$CONFIGS_RESTIC_REPO"
}

# check_logs_integrity
#
# Verifies the logs S3 bucket is accessible and contains data.
# Note: logs backup uses `aws s3 sync` (not restic), so `restic check` is not applicable.
# Checks: .last-sync sentinel readable + non-zero object count.
check_logs_integrity() {
    log "S3 path: ${LOGS_S3_PATH}"
    log "Method: aws s3 sync (no restic repository — S3 accessibility check)"

    # Verify the .last-sync sentinel exists and is readable
    local tmp_sentinel
    tmp_sentinel=$(mktemp)

    if ! aws s3 cp "${LOGS_S3_PATH}/.last-sync" "$tmp_sentinel" >/dev/null 2>&1; then
        rm -f "$tmp_sentinel"
        log "✗ Could not retrieve .last-sync from ${LOGS_S3_PATH} — bucket inaccessible or first sync has not run"
        return 1
    fi

    local sync_time
    sync_time=$(cut -d' ' -f1 "$tmp_sentinel")
    rm -f "$tmp_sentinel"

    if [[ -z "$sync_time" ]]; then
        log "✗ .last-sync sentinel is empty or malformed"
        return 1
    fi

    # Spot-check that S3 objects exist beyond the sentinel
    local s3_count
    s3_count=$(aws s3 ls --recursive "${LOGS_S3_PATH}/" 2>/dev/null | wc -l)

    if [[ "$s3_count" -eq 0 ]]; then
        log "✗ No objects found in logs S3 bucket at ${LOGS_S3_PATH}"
        return 1
    fi

    log "✓ Logs S3 bucket accessible: ${s3_count} objects found, last sync: ${sync_time}"
    return 0
}

# ─── PostgreSQL restore test wrapper ────────────────────────────────────────

# run_postgres_restore_test
#
# Calls backups/postgres/restore-test.sh, which runs the full restore + validation
# and sends its own detailed Discord message on completion.
# This function exists so it can be tracked via run_integrity_check.
run_postgres_restore_test() {
    local script="${BACKUPS_DIR}/postgres/restore-test.sh"

    if [[ ! -x "$script" ]]; then
        log "✗ ${script} not found or not executable"
        return 1
    fi

    log "  (Detailed pass/fail report will be sent as a separate Discord message)"
    bash "$script"
}

# ─── Discord reporting ───────────────────────────────────────────────────────

send_combined_report() {
    local duration_secs=$(( $(date +%s) - START_TIME ))
    local duration_str
    duration_str=$(format_duration "$duration_secs")

    local description="**Monthly restore test results (${PASSED_CHECKS}/${TOTAL_CHECKS} passed)**\n\n"
    for result in "${INTEGRITY_RESULTS[@]}"; do
        description+="${result}\n"
    done
    description+="\n**Total duration:** ${duration_str}"

    if [[ "${#FAILED_CHECKS[@]}" -eq 0 ]]; then
        send_discord "Restore Test: All Checks Passed" "$description" 5763719 "✅"
    else
        description+="\n\n**Failed checks:**\n"
        for check in "${FAILED_CHECKS[@]}"; do
            description+="  • ${check}\n"
        done
        description+="\n**Action required:** Check logs in \`logs/restore/\`"
        send_discord "Restore Test: Monthly Checks FAILED" "$description" 15548997 "🔴"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

log "=== Restore Test Run Started ==="
log "Log file: $LOG_FILE"
log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
log ""
log "Phase 1: Repository integrity checks"
log "Scope: Foundry restic, Configs restic, Logs S3"
log ""
log "Phase 2: PostgreSQL restore test"
log "Scope: pgBackRest restore → start → validate databases/schema/PostGIS/row counts"
log ""

# Load credentials (needed by all checks)
log "Loading secrets..."
if [[ ! -f "${SECRETS_DIR}/aws.env" ]]; then
    log "ERROR: ${SECRETS_DIR}/aws.env not found"
    exit $EXIT_ERROR
fi
source "${SECRETS_DIR}/aws.env"

if [[ ! -f "${SECRETS_DIR}/restic.key" ]]; then
    log "ERROR: ${SECRETS_DIR}/restic.key not found"
    exit $EXIT_ERROR
fi
export RESTIC_PASSWORD
RESTIC_PASSWORD=$(cat "${SECRETS_DIR}/restic.key")
log "✓ Secrets loaded"

# Phase 1: Repository integrity checks — continue through failures to collect all results
run_integrity_check "Foundry restic repository" check_foundry_integrity || true
run_integrity_check "Configs restic repository" check_configs_integrity || true
run_integrity_check "Logs S3 bucket"            check_logs_integrity    || true

# Phase 2: PostgreSQL restore test (sends its own detailed Discord message)
log ""
log "=== Phase 2: PostgreSQL Restore Test ==="
run_integrity_check "PostgreSQL restore test" run_postgres_restore_test || true

# Summary
log ""
log "=== Restore Test Summary ==="
log "Passed: ${PASSED_CHECKS}/${TOTAL_CHECKS}"
if [[ "${#FAILED_CHECKS[@]}" -gt 0 ]]; then
    log "Failed checks:"
    for check in "${FAILED_CHECKS[@]}"; do
        log "  ✗ ${check}"
    done
fi

run_duration=$(( $(date +%s) - START_TIME ))
log "Total duration: $(format_duration "$run_duration")"

# Send combined Discord summary (integrity checks + restore test pass/fail)
send_combined_report

# Exit with failure if any check failed
if [[ "${#FAILED_CHECKS[@]}" -gt 0 ]]; then
    exit $EXIT_ERROR
fi

exit $EXIT_SUCCESS
