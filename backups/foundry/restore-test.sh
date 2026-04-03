#!/bin/bash
# Foundry Restore Test
# Phase 5 Part 3: Full restore test with startup validation
#
# Restores latest Foundry backup snapshot to a temporary location,
# validates expected structure and file count, then boots a temporary
# Foundry container and verifies HTTP readiness.
#
# Logs:     logs/restore/foundry/
# Schedule: Called from backups/orchestration/restore-test.sh (monthly, 4:00 AM)

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
STACK_DIR="$(realpath "$BACKUPS_DIR/..")"
SECRETS_DIR="${BACKUPS_DIR}/secrets"
FOUNDRY_ENV_FILE="${STACK_DIR}/foundry/secrets/foundry.env"
FOUNDRY_CACHE_DIR="${STACK_DIR}/foundry/data/container_cache"

# Load shared wrapper library (also loads config.sh via setup_wrapper)
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging to logs/restore/foundry/
LOG_DIR="${STACK_DIR}/logs/restore/foundry"
setup_wrapper "$LOG_DIR" "foundry-restore-test"

# Install timeout trap handler
install_timeout_trap

# Load Discord notification library
source "${BACKUPS_DIR}/monitoring/scripts/discord-lib.sh"
DISCORD_ENV="${SECRETS_DIR}/discord.env"
if [[ -f "$DISCORD_ENV" ]]; then
    source "$DISCORD_ENV"
fi

# ─── Constants ───────────────────────────────────────────────────────────────

RESTORE_CONTAINER="foundry-restore-test"
# Must be outside /tmp: PrivateTmp=yes in the systemd service gives the process a
# private /tmp namespace, so Docker (which runs in the host namespace) cannot
# bind-mount paths under /tmp written by this script.
TEMP_DIR="${STACK_DIR}/tmp/foundry-restore-test"
FOUNDRY_IMAGE="felddy/foundryvtt:13.351"
FOUNDRY_PORT=30002
STARTUP_TIMEOUT=90

# Baseline from implementation notes: ~10,738 files.
# Keep threshold lower to avoid false failures while still catching truncated restores.
MIN_EXPECTED_FILES=8000

# ─── State tracking ──────────────────────────────────────────────────────────

RESTORE_DURATION=0
STARTUP_DURATION=0
RESTORE_PASSED=false
STARTUP_PASSED=false
FILE_COUNT=0
OVERALL_RESULT="FAILED"
RESULT_NOTES=()
RESTORED_DATA_DIR=""

# ─── Helpers ─────────────────────────────────────────────────────────────────

fail_preflight() {
    local message="$1"
    log "ERROR: ${message}"
    send_discord "Foundry Restore Test: FAILED" "${message}" 15548997 "🔴"
    exit $EXIT_ERROR
}

cleanup() {
    log ""
    log "--- Cleanup ---"

    if docker inspect "$RESTORE_CONTAINER" >/dev/null 2>&1; then
        log "Stopping and removing container: ${RESTORE_CONTAINER}"
        docker stop "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
        docker rm "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
        log "✓ Container removed"
    fi

    if [[ -d "$TEMP_DIR" ]]; then
        log "Removing temporary directory: ${TEMP_DIR}"
        rm -rf "$TEMP_DIR"
        log "✓ Temp directory removed"
    fi
}

trap 'cleanup' EXIT

find_single_dir() {
    local root="$1"
    local name="$2"
    find "$root" -type d -name "$name" 2>/dev/null | head -1
}

run_restore_phase() {
    log "--- Phase 1: Restic Restore ---"

    mkdir -p "$TEMP_DIR"

    local restore_start
    restore_start=$(date +%s)

    local restore_output
    local restore_exit=0

    restore_output=$(restic -r "$FOUNDRY_RESTIC_REPO" restore latest --target "$TEMP_DIR" 2>&1) || restore_exit=$?
    echo "$restore_output" | tee -a "$LOG_FILE"

    RESTORE_DURATION=$(( $(date +%s) - restore_start ))
    log ""

    if [[ $restore_exit -ne 0 ]]; then
        log "✗ restic restore failed (exit: ${restore_exit}) after $(format_duration "$RESTORE_DURATION")"
        RESULT_NOTES+=("Restore phase failed (exit: ${restore_exit})")
        return 1
    fi

    local data_dir
    data_dir=$(find_single_dir "$TEMP_DIR" "Data")
    local config_dir
    config_dir=$(find_single_dir "$TEMP_DIR" "Config")

    if [[ -z "$data_dir" || -z "$config_dir" ]]; then
        log "✗ Expected restored directories not found (Data/Config)"
        RESULT_NOTES+=("Expected Data/Config directories were not found after restore")
        return 1
    fi

    local data_parent
    data_parent=$(dirname "$data_dir")
    local config_parent
    config_parent=$(dirname "$config_dir")

    if [[ "$data_parent" != "$config_parent" ]]; then
        log "✗ Data and Config directories were restored to different parents"
        RESULT_NOTES+=("Data and Config directory parents differ; cannot mount a single /data root")
        return 1
    fi

    RESTORED_DATA_DIR="$data_parent"

    FILE_COUNT=$(find "$RESTORED_DATA_DIR" -type f | wc -l | xargs)
    log "Restored data root: ${RESTORED_DATA_DIR}"
    log "Restored file count: ${FILE_COUNT}"

    if [[ ! "$FILE_COUNT" =~ ^[0-9]+$ ]]; then
        log "✗ Restored file count is not numeric"
        RESULT_NOTES+=("Could not determine restored file count")
        return 1
    fi

    if [[ "$FILE_COUNT" -lt "$MIN_EXPECTED_FILES" ]]; then
        log "✗ Restored file count ${FILE_COUNT} is below minimum expected ${MIN_EXPECTED_FILES}"
        RESULT_NOTES+=("File count below threshold: ${FILE_COUNT} < ${MIN_EXPECTED_FILES}")
        return 1
    fi

    log "✓ Restore completed in $(format_duration "$RESTORE_DURATION")"

    # The restore runs as root (systemd), but the Foundry container starts as
    # uid:gid 1000:1000 and fails its volume write test if /data is root-owned.
    log "Setting ownership of restored data to 1000:1000 for Foundry container..."
    chown -R 1000:1000 "$RESTORED_DATA_DIR"
    log "✓ Ownership set"

    RESTORE_PASSED=true
    return 0
}

run_startup_phase() {
    log ""
    log "--- Phase 2: Foundry Startup Verification ---"

    local startup_start
    startup_start=$(date +%s)

    local docker_cmd=(
        docker run -d
        --name "$RESTORE_CONTAINER"
        -p "${FOUNDRY_PORT}:30000"
        --env-file "$FOUNDRY_ENV_FILE"
        -v "${RESTORED_DATA_DIR}:/data"
    )

    # Reuse existing cached Foundry zip so the test container can start without
    # a fresh authenticated download.
    if [[ -f "${FOUNDRY_CACHE_DIR}/foundryvtt-13.351.zip" ]]; then
        docker_cmd+=(
            -e "CONTAINER_CACHE=/data/container_cache"
            -v "${FOUNDRY_CACHE_DIR}:/data/container_cache"
        )
        log "Using cached Foundry artifact from ${FOUNDRY_CACHE_DIR}"
    fi

    docker_cmd+=("$FOUNDRY_IMAGE")
    "${docker_cmd[@]}" >/dev/null

    log "Waiting for Foundry HTTP readiness on http://localhost:${FOUNDRY_PORT}/ (timeout: ${STARTUP_TIMEOUT}s)..."

    local elapsed=0
    while [[ $elapsed -lt $STARTUP_TIMEOUT ]]; do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$RESTORE_CONTAINER" 2>/dev/null || echo false)" != "true" ]]; then
            log "✗ Foundry test container exited during startup"
            RESULT_NOTES+=("Foundry test container exited during startup")
            break
        fi

        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${FOUNDRY_PORT}/" || true)

        if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
            STARTUP_DURATION=$(( $(date +%s) - startup_start ))
            log "✓ Foundry HTTP ready after ${STARTUP_DURATION}s (HTTP ${http_code})"
            STARTUP_PASSED=true
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    STARTUP_DURATION=$(( $(date +%s) - startup_start ))
    log "✗ Foundry did not become HTTP-ready within ${STARTUP_TIMEOUT}s"
    log "Last 40 container log lines:"
    docker logs --tail 40 "$RESTORE_CONTAINER" 2>&1 | tee -a "$LOG_FILE" || true
    RESULT_NOTES+=("Foundry HTTP readiness failed within ${STARTUP_TIMEOUT}s")
    return 1
}

send_restore_report() {
    local total_duration=$(( $(date +%s) - START_TIME ))
    local duration_str
    duration_str=$(format_duration "$total_duration")
    local restore_str
    restore_str=$(format_duration "$RESTORE_DURATION")

    local description
    if [[ "$OVERALL_RESULT" == "PASSED" ]]; then
        description="**Restore:** ✅ Completed in ${restore_str}\\n"
        description+="**Structure:** ✅ Data/Config found under restored /data root\\n"
        description+="**File count:** ✅ ${FILE_COUNT} files\\n"
        description+="**Startup:** ✅ Foundry ready in ${STARTUP_DURATION}s on port ${FOUNDRY_PORT}\\n"
        description+="\\n**Total duration:** ${duration_str}"
        send_discord "Foundry Restore Test: PASSED" "$description" 5763719 "✅"
    else
        local restore_status
        restore_status="$([ "$RESTORE_PASSED" == "true" ] && echo "✅ ${restore_str}" || echo "❌ Failed")"
        local startup_status
        startup_status="$([ "$STARTUP_PASSED" == "true" ] && echo "✅ ${STARTUP_DURATION}s" || echo "❌ Failed")"

        description="**Restore:** ${restore_status}\\n"
        description+="**Startup:** ${startup_status}\\n"
        description+="**File count:** ${FILE_COUNT}\\n"
        description+="**Total duration:** ${duration_str}\\n"

        if [[ ${#RESULT_NOTES[@]} -gt 0 ]]; then
            description+="\\n**Issues:**\\n"
            for note in "${RESULT_NOTES[@]}"; do
                description+="  • ${note}\\n"
            done
        fi

        description+="\n**Action required:** Check logs/restore/foundry/"
        send_discord "Foundry Restore Test: FAILED" "$description" 15548997 "🔴"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

log "=== Foundry Restore Test Started ==="
log "Log file: $LOG_FILE"
log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
log "Image: ${FOUNDRY_IMAGE}"
log "Port: ${FOUNDRY_PORT}"
log ""

# Preflight checks
if ! command -v restic >/dev/null 2>&1; then
    fail_preflight "restic command not found"
fi
if ! command -v curl >/dev/null 2>&1; then
    fail_preflight "curl command not found"
fi
if ! docker info >/dev/null 2>&1; then
    fail_preflight "Docker daemon is not accessible. Run as root/sudo or ensure Docker permissions are configured."
fi
if [[ ! -f "$FOUNDRY_ENV_FILE" ]]; then
    fail_preflight "Missing Foundry env file: ${FOUNDRY_ENV_FILE}"
fi
if [[ ! -f "${SECRETS_DIR}/aws.env" ]]; then
    fail_preflight "Missing AWS credentials: ${SECRETS_DIR}/aws.env"
fi
if [[ ! -f "${SECRETS_DIR}/restic.key" ]]; then
    fail_preflight "Missing restic key: ${SECRETS_DIR}/restic.key"
fi
if ! docker image inspect "$FOUNDRY_IMAGE" >/dev/null 2>&1; then
    fail_preflight "Foundry image '${FOUNDRY_IMAGE}' not found locally"
fi

if command -v ss >/dev/null 2>&1; then
    if ss -tln "( sport = :${FOUNDRY_PORT} )" 2>/dev/null | grep -q ":${FOUNDRY_PORT}"; then
        fail_preflight "Port ${FOUNDRY_PORT} is already in use"
    fi
elif command -v netstat >/dev/null 2>&1; then
    if netstat -tln 2>/dev/null | awk '{print $4}' | grep -E "(^|:)${FOUNDRY_PORT}$" >/dev/null; then
        fail_preflight "Port ${FOUNDRY_PORT} is already in use"
    fi
fi

if docker inspect "$RESTORE_CONTAINER" >/dev/null 2>&1; then
    log "WARNING: Found leftover container '${RESTORE_CONTAINER}' — removing before starting"
    docker stop "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
    docker rm "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
fi
if [[ -d "$TEMP_DIR" ]]; then
    log "WARNING: Found leftover temp directory '${TEMP_DIR}' — removing before starting"
    rm -rf "$TEMP_DIR"
fi

log "Loading secrets..."
source "${SECRETS_DIR}/aws.env"
export RESTIC_PASSWORD
RESTIC_PASSWORD=$(cat "${SECRETS_DIR}/restic.key")
log "✓ Secrets loaded"
log ""

if ! run_restore_phase; then
    log ""
    log "=== Foundry Restore Test FAILED ==="
    send_restore_report
    exit $EXIT_ERROR
fi

if ! run_startup_phase; then
    log ""
    log "=== Foundry Restore Test FAILED ==="
    send_restore_report
    exit $EXIT_ERROR
fi

OVERALL_RESULT="PASSED"
log ""
log "=== Foundry Restore Test PASSED ==="
log "Restore duration: $(format_duration "$RESTORE_DURATION")"
log "Startup duration: $(format_duration "$STARTUP_DURATION")"
log "Total duration:   $(format_duration $(( $(date +%s) - START_TIME )))"
send_restore_report
exit $EXIT_SUCCESS
