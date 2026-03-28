#!/bin/bash
# PostgreSQL Restore Test
# Phase 5 Part 2: Full restore test with data validation
#
# Restores the latest pgBackRest backup to a temporary location, starts a test
# PostgreSQL instance on port 5433, and validates data integrity against the
# live production database.
#
# Pass criteria:
# - pgBackRest restore completes without error
# - PostgreSQL starts and accepts connections within 90s
# - All production databases present in restored backup
# - All tables in the target schema present in restored backup (schema migration check)
# - PostGIS extension present in VALIDATE_DB
# - Every table in VALIDATE_SCHEMA: restored count >= 99% of production count
#
# Logs:     logs/restore/postgresql/
# Schedule: Called from backups/orchestration/restore-test.sh (monthly, 4:00 AM)

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
STACK_DIR="$(realpath "$BACKUPS_DIR/..")"
DB_DIR="${STACK_DIR}/db"
SECRETS_DIR="${BACKUPS_DIR}/secrets"

# Load shared wrapper library (also loads config.sh via setup_wrapper)
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging to logs/restore/postgresql/
LOG_DIR="${STACK_DIR}/logs/restore/postgresql"
setup_wrapper "$LOG_DIR" "restore-test"

# Install timeout trap handler
install_timeout_trap

# Load Discord notification library
source "${BACKUPS_DIR}/monitoring/scripts/discord-lib.sh"
DISCORD_ENV="${SECRETS_DIR}/discord.env"
if [[ -f "$DISCORD_ENV" ]]; then
    source "$DISCORD_ENV"
fi

# ─── Constants ───────────────────────────────────────────────────────────────

# Container name for the validation PostgreSQL instance
RESTORE_CONTAINER="postgres-restore-test"

# Temporary directory for restore data
TEMP_DIR="/tmp/postgres-restore-test"

# Port to run restored PostgreSQL on (avoid conflicting with production :5432)
RESTORE_PORT=5433

# Seconds to wait for PostgreSQL to become ready after restore
POSTGRES_STARTUP_TIMEOUT=300

# Docker image (must match production db/compose.yml)
DB_IMAGE="keithmoss/postgres-pgbackrest:15"

# Databases to validate end-to-end (table inventory + row counts + PostGIS)
VALIDATE_DBS=("mapa_staging" "demsausage_staging")

# ─── State tracking ──────────────────────────────────────────────────────────

RESTORE_DURATION=0
RESTORE_PASSED=false
VALIDATION_PASSED=false
BELOW_THRESHOLD_TABLES=()
OVERALL_RESULT="FAILED"
RESULT_NOTES=()
POSTGRES_UID=""
POSTGRES_GID=""
declare -A DB_ROW_TOTALS=()
declare -A DB_ROW_PASSED=()

# fail_preflight
#
# Logs a preflight failure, sends Discord alert, and exits with error.
#
# Arguments:
#   $1 - Failure message
fail_preflight() {
    local message="$1"
    log "ERROR: ${message}"
    send_discord "PostgreSQL Restore Test: FAILED" "${message}" 15548997 "🔴"
    exit $EXIT_ERROR
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

# cleanup
#
# Stops/removes the test container and deletes the temporary data directory.
# Registered as an EXIT trap so it runs even if the script errors out.
cleanup() {
    log ""
    log "--- Cleanup ---"

    if docker inspect "$RESTORE_CONTAINER" >/dev/null 2>&1; then
        log "Stopping and removing container: ${RESTORE_CONTAINER}"
        docker stop "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
        docker rm   "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
        log "✓ Container removed"
    fi

    if [[ -d "$TEMP_DIR" ]]; then
        log "Removing temporary directory: ${TEMP_DIR}"
        rm -rf "$TEMP_DIR"
        log "✓ Temp directory removed"
    fi
}

trap 'cleanup' EXIT

# ─── DB query helpers ────────────────────────────────────────────────────────

# psql_prod
#
# Runs a query against the live production database via docker exec.
# Connects over the Unix socket inside the container (no password needed).
#
# Arguments:
#   $1 - Database name
#   $2 - SQL query
psql_prod() {
    local dbname="$1"
    local query="$2"
    docker exec "$POSTGRES_DB_CONTAINER" psql -U postgres -d "$dbname" -t -A -c "$query"
}

# psql_test
#
# Runs a query against the restored test database via docker exec.
#
# Arguments:
#   $1 - Database name
#   $2 - SQL query
psql_test() {
    local dbname="$1"
    local query="$2"
    docker exec "$RESTORE_CONTAINER" psql -U postgres -d "$dbname" -t -A -c "$query"
}

# ─── Restore phase ───────────────────────────────────────────────────────────

# run_restore_phase
#
# Runs the pgBackRest restore into TEMP_DIR/data using an ephemeral container.
# Mounts the same config and credentials as production.
# Sets RESTORE_PASSED and RESTORE_DURATION as side effects.
run_restore_phase() {
    log "--- Phase 1: pgBackRest Restore ---"

    mkdir -p "${TEMP_DIR}/data" "${TEMP_DIR}/pg_log" "${TEMP_DIR}/pgbackrest_log"
    chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "${TEMP_DIR}"
    log "✓ Temp directory created: ${TEMP_DIR}"

    local restore_start
    restore_start=$(date +%s)

    log "Restoring latest backup (type=default) into ${TEMP_DIR}/data..."
    log "Image: ${DB_IMAGE}"
    log ""

    # Capture output; || exit_code=$? prevents set -e from exiting on restore failure
    local restore_output
    local restore_exit=0
    restore_output=$(
        docker run --rm \
            -v "${TEMP_DIR}/data:/var/lib/postgresql/data" \
            -v "${TEMP_DIR}/pgbackrest_log:/var/log/pgbackrest" \
            -v "${DB_DIR}/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro" \
            -v "${DB_DIR}/pgbackrest-wrapper.sh:/usr/local/bin/pgbackrest-wrapper:ro" \
            -v "${SECRETS_DIR}:/run/secrets:ro" \
            "$DB_IMAGE" \
            /usr/local/bin/pgbackrest-wrapper --stanza=main restore --type=default \
            2>&1
    ) || restore_exit=$?

    echo "$restore_output" | tee -a "$LOG_FILE"

    RESTORE_DURATION=$(( $(date +%s) - restore_start ))
    log ""

    if [[ $restore_exit -ne 0 ]]; then
        log "✗ pgBackRest restore failed (exit: ${restore_exit}) after $(format_duration $RESTORE_DURATION)"
        RESULT_NOTES+=("Restore phase failed (exit: ${restore_exit}) — check pgBackRest output above")
        return 1
    fi

    log "✓ pgBackRest restore completed in $(format_duration $RESTORE_DURATION)"
    RESTORE_PASSED=true
    return 0
}

# ─── Validation phase ────────────────────────────────────────────────────────

# start_test_postgres
#
# Starts the restored PostgreSQL instance in a detached container on RESTORE_PORT.
# Polls pg_isready until the instance accepts connections or POSTGRES_STARTUP_TIMEOUT is reached.
#
# Key overrides vs. production:
#   archive_mode=off          — prevents spurious WAL archiving to S3 during the test
#   recovery_target=immediate — promotes as soon as backup consistency is reached,
#                               without waiting for restore_command to fetch extra WAL from S3
#   recovery_target_action=promote — automatically switch to normal operation after recovery
start_test_postgres() {
    log ""
    log "--- Phase 2a: Start Test PostgreSQL Instance ---"
    log "Container: ${RESTORE_CONTAINER}  Port: ${RESTORE_PORT}"

    docker run -d \
        --name "$RESTORE_CONTAINER" \
        -p "${RESTORE_PORT}:5432" \
        -e "PGBACKREST_REPO1_S3_KEY=${AWS_ACCESS_KEY_ID}" \
        -e "PGBACKREST_REPO1_S3_KEY_SECRET=${AWS_SECRET_ACCESS_KEY}" \
        -v "${TEMP_DIR}/data:/var/lib/postgresql/data" \
        -v "${TEMP_DIR}/pg_log:/etc/postgresql/pg_log" \
        -v "${TEMP_DIR}/pgbackrest_log:/var/log/pgbackrest" \
        -v "${DB_DIR}/postgresql.conf:/etc/postgresql/postgresql.conf:ro" \
        -v "${DB_DIR}/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro" \
        -v "${DB_DIR}/pgbackrest-wrapper.sh:/usr/local/bin/pgbackrest-wrapper:ro" \
        -v "${SECRETS_DIR}:/run/secrets:ro" \
        "$DB_IMAGE" \
        postgres \
            -c 'config_file=/etc/postgresql/postgresql.conf' \
            -c 'archive_mode=off' \
            -c 'logging_collector=off' \
            -c 'recovery_target=immediate' \
            -c 'recovery_target_action=promote' \
        >/dev/null

    log "Waiting for PostgreSQL to accept connections (timeout: ${POSTGRES_STARTUP_TIMEOUT}s)..."

    local elapsed=0
    while [[ $elapsed -lt $POSTGRES_STARTUP_TIMEOUT ]]; do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$RESTORE_CONTAINER" 2>/dev/null || echo false)" != "true" ]]; then
            log "✗ Test container exited during startup"
            RESULT_NOTES+=("Test container exited during PostgreSQL startup")
            break
        fi
        if docker exec "$RESTORE_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
            log "✓ PostgreSQL ready after ${elapsed}s"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log "✗ PostgreSQL did not become ready within ${POSTGRES_STARTUP_TIMEOUT}s"
    local ready_output
    ready_output=$(docker exec "$RESTORE_CONTAINER" pg_isready -U postgres 2>&1 || true)
    log "pg_isready output: ${ready_output}"
    log "Last 30 container log lines:"
    docker logs --tail 30 "$RESTORE_CONTAINER" 2>&1 | tee -a "$LOG_FILE" || true
    if compgen -G "${TEMP_DIR}/pg_log/*" > /dev/null; then
        log "Last 30 lines from ${TEMP_DIR}/pg_log/ files:"
        tail -n 30 "${TEMP_DIR}/pg_log"/* 2>&1 | tee -a "$LOG_FILE" || true
    fi
    RESULT_NOTES+=("Test PostgreSQL did not start within ${POSTGRES_STARTUP_TIMEOUT}s")
    return 1
}

# validate_databases
#
# Verifies that every non-template database in production also exists in the
# restored backup (restored ⊇ production).
validate_databases() {
    log ""
    log "--- Phase 2b: Database Presence Check ---"

    local prod_dbs
    prod_dbs=$(psql_prod postgres \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;")

    local test_dbs
    test_dbs=$(psql_test postgres \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;")

    log "Production databases: $(echo "$prod_dbs" | tr '\n' ' ' | xargs)"
    log "Restored databases:   $(echo "$test_dbs"  | tr '\n' ' ' | xargs)"

    local missing_dbs=()
    while IFS= read -r db; do
        db=$(echo "$db" | xargs)
        [[ -z "$db" ]] && continue
        if ! echo "$test_dbs" | grep -qx "$db"; then
            missing_dbs+=("$db")
        fi
    done <<< "$prod_dbs"

    if [[ ${#missing_dbs[@]} -gt 0 ]]; then
        log "✗ Missing databases in restored backup: ${missing_dbs[*]}"
        RESULT_NOTES+=("Missing databases in restored backup: ${missing_dbs[*]}")
        return 1
    fi

    log "✓ All production databases present in restored backup"
    return 0
}

# validate_table_inventory
#
# For each validation database, checks that every non-system table in
# production also exists in the restored backup.
validate_table_inventory() {
    log ""
    log "--- Phase 2c: Table Inventory Check (${VALIDATE_DBS[*]}) ---"

    local overall_ok=true

    for validate_db in "${VALIDATE_DBS[@]}"; do
        local db_exists
        db_exists=$(psql_test postgres \
            "SELECT 1 FROM pg_database WHERE datname = '${validate_db}';" 2>/dev/null || echo "")

        if [[ -z "$db_exists" || "$db_exists" != "1" ]]; then
            log "✗ Database '${validate_db}' not found in restored backup"
            RESULT_NOTES+=("Database '${validate_db}' missing from restored backup")
            overall_ok=false
            continue
        fi

        local prod_tables
        prod_tables=$(psql_prod "$validate_db" \
            "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY schemaname, tablename;")

        local test_tables
        test_tables=$(psql_test "$validate_db" \
            "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY schemaname, tablename;")

        local prod_count
        prod_count=$(echo "$prod_tables" | grep -c '[^[:space:]]' || true)
        local test_count
        test_count=$(echo "$test_tables" | grep -c '[^[:space:]]' || true)

        log "${validate_db}: production tables=${prod_count}, restored tables=${test_count}"

        local missing_tables=()
        while IFS= read -r tbl; do
            tbl=$(echo "$tbl" | xargs)
            [[ -z "$tbl" ]] && continue
            if ! echo "$test_tables" | grep -qx "$tbl"; then
                missing_tables+=("$tbl")
            fi
        done <<< "$prod_tables"

        if [[ ${#missing_tables[@]} -gt 0 ]]; then
            log "✗ ${validate_db}: missing ${#missing_tables[@]} table(s) in restored backup"
            RESULT_NOTES+=("${validate_db}: missing tables in restored backup (${#missing_tables[@]})")
            overall_ok=false
        else
            log "✓ ${validate_db}: all ${prod_count} production tables present"
        fi
    done

    [[ "$overall_ok" == "true" ]]
}

# validate_postgis
#
# Verifies the PostGIS extension is present and callable in each validation DB.
validate_postgis() {
    log ""
    log "--- Phase 2d: PostGIS Extension Check (${VALIDATE_DBS[*]}) ---"

    local overall_ok=true
    for validate_db in "${VALIDATE_DBS[@]}"; do
        local postgis_ver
        postgis_ver=$(psql_test "$validate_db" "SELECT postgis_version();" 2>/dev/null | head -1 | xargs || true)

        if [[ -n "$postgis_ver" && "$postgis_ver" != "ERROR"* ]]; then
            log "✓ ${validate_db}: PostGIS present (${postgis_ver})"
        else
            log "✗ ${validate_db}: PostGIS extension not available"
            RESULT_NOTES+=("PostGIS extension missing or failed in ${validate_db}")
            overall_ok=false
        fi
    done

    [[ "$overall_ok" == "true" ]]
}

# validate_row_counts
#
# For every non-system table in every validation database, compares row counts
# in the restored backup against live production. A restored count below 99% of
# the production count is treated as a failure (the 1% tolerance accepts a
# small number of legitimate production writes since the backup was taken).
validate_row_counts() {
    log ""
    log "--- Phase 2e: Row Count Validation (${VALIDATE_DBS[*]}) ---"
    log "Threshold: restored count >= 99% of production count"
    log ""

    local total=0 passed=0
    local all_ok=true

    for validate_db in "${VALIDATE_DBS[@]}"; do
        DB_ROW_TOTALS["$validate_db"]=0
        DB_ROW_PASSED["$validate_db"]=0
    done

    printf "%-20s %-45s %12s %12s  %s\n" \
        "Database" "Table" "Production" "Restored" "Status" | tee -a "$LOG_FILE"
    printf "%-20s %-45s %12s %12s  %s\n" \
        "────────────────────" "─────────────────────────────────────────────" \
        "──────────" "──────────" "──────" | tee -a "$LOG_FILE"

    for validate_db in "${VALIDATE_DBS[@]}"; do
        local tables
        tables=$(psql_prod "$validate_db" \
            "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY schemaname, tablename;")

        while IFS= read -r full_tbl; do
            full_tbl=$(echo "$full_tbl" | xargs)
            [[ -z "$full_tbl" ]] && continue
            total=$((total + 1))
            DB_ROW_TOTALS["$validate_db"]=$(( ${DB_ROW_TOTALS["$validate_db"]} + 1 ))

            local prod_cnt
            prod_cnt=$(psql_prod "$validate_db" \
                "SELECT count(*) FROM ${full_tbl};" 2>/dev/null | xargs || echo "ERROR")

            local test_cnt
            test_cnt=$(psql_test "$validate_db" \
                "SELECT count(*) FROM ${full_tbl};" 2>/dev/null | xargs || echo "ERROR")

            local status="PASS"
            if [[ "$prod_cnt" == "ERROR" || "$test_cnt" == "ERROR" ]]; then
                status="ERROR"
                all_ok=false
                BELOW_THRESHOLD_TABLES+=("${validate_db}.${full_tbl} (query error)")
            elif [[ "$prod_cnt" -gt 0 ]]; then
                local threshold=$(( prod_cnt * 99 / 100 ))
                if [[ "$test_cnt" -lt "$threshold" ]]; then
                    local pct=$(( test_cnt * 100 / prod_cnt ))
                    status="FAIL"
                    all_ok=false
                    BELOW_THRESHOLD_TABLES+=("${validate_db}.${full_tbl}: restored=${test_cnt} prod=${prod_cnt} (${pct}%)")
                fi
            fi

            [[ "$status" == "PASS" ]] && passed=$((passed + 1))
            if [[ "$status" == "PASS" ]]; then
                DB_ROW_PASSED["$validate_db"]=$(( ${DB_ROW_PASSED["$validate_db"]} + 1 ))
            fi
            printf "%-20s %-45s %12s %12s  %s\n" "$validate_db" "${full_tbl}" "$prod_cnt" "$test_cnt" "$status" \
                | tee -a "$LOG_FILE"
        done <<< "$tables"
    done

    log ""
    log "Row count results: ${passed}/${total} tables passed"
    for validate_db in "${VALIDATE_DBS[@]}"; do
        log "  ${validate_db}: ${DB_ROW_PASSED["$validate_db"]}/${DB_ROW_TOTALS["$validate_db"]} tables passed"
    done

    if [[ "$all_ok" == "true" ]]; then
        log "✓ All tables within 99% threshold"
        return 0
    fi

    log "✗ ${#BELOW_THRESHOLD_TABLES[@]} table(s) below threshold:"
    for t in "${BELOW_THRESHOLD_TABLES[@]}"; do
        log "  ✗ ${t}"
    done
    return 1
}

# run_validation_phase
#
# Runs all validation checks against the restored PostgreSQL instance.
# All checks are attempted even if earlier ones fail, so we collect the
# full picture before reporting.
run_validation_phase() {
    if ! start_test_postgres; then
        return 1
    fi

    local ok=true
    validate_databases  || ok=false
    validate_table_inventory || ok=false
    validate_postgis    || ok=false
    validate_row_counts || ok=false

    if [[ "$ok" == "true" ]]; then
        VALIDATION_PASSED=true
        return 0
    fi
    return 1
}

# ─── Discord reporting ───────────────────────────────────────────────────────

send_restore_report() {
    local total_duration=$(( $(date +%s) - START_TIME ))
    local duration_str
    duration_str=$(format_duration "$total_duration")
    local restore_str
    restore_str=$(format_duration "$RESTORE_DURATION")

    local description
    if [[ "$OVERALL_RESULT" == "PASSED" ]]; then
        description="**Restore:** ✅ Completed in ${restore_str}\n"
        description+="**Startup:** ✅ PostgreSQL accepted connections\n"
        description+="**Databases:** ✅ All production databases present\n"
        description+="**Table inventory:** ✅ All production user tables present in restored DBs (${VALIDATE_DBS[*]})\n"
        description+="**PostGIS:** ✅ Extension present in all validation DBs (${VALIDATE_DBS[*]})\n"
        description+="**Row counts:** ✅ All user tables ≥ 99% of production\n"
        for validate_db in "${VALIDATE_DBS[@]}"; do
            description+="  • ${validate_db}: ${DB_ROW_PASSED["$validate_db"]}/${DB_ROW_TOTALS["$validate_db"]} tables passed\n"
        done
        description+="\n**Total duration:** ${duration_str}"
        send_discord "PostgreSQL Restore Test: PASSED" "$description" 5763719 "✅"
    else
        local restore_status
        restore_status="$([ "$RESTORE_PASSED" == "true" ] && echo "✅ ${restore_str}" || echo "❌ Failed")"
        local validation_status
        validation_status="$([ "$VALIDATION_PASSED" == "true" ] && echo "✅" || echo "❌ Failed")"

        description="**Restore:** ${restore_status}\n"
        description+="**Validation:** ${validation_status}\n"
        description+="**Total duration:** ${duration_str}\n"

        if [[ ${#RESULT_NOTES[@]} -gt 0 ]]; then
            description+="\n**Issues:**\n"
            for note in "${RESULT_NOTES[@]}"; do
                description+="  • ${note}\n"
            done
        fi

        if [[ ${#BELOW_THRESHOLD_TABLES[@]} -gt 0 ]]; then
            description+="\n**Tables below 99% threshold:**\n"
            for t in "${BELOW_THRESHOLD_TABLES[@]}"; do
                description+="  • ${t}\n"
            done
        fi

        description+="\n**Action required:** Check \`logs/restore/postgresql/\`"
        send_discord "PostgreSQL Restore Test: FAILED" "$description" 15548997 "🔴"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

log "=== PostgreSQL Restore Test Started ==="
log "Log file: $LOG_FILE"
log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
log "Image: ${DB_IMAGE}"
log "Validate DBs: ${VALIDATE_DBS[*]}"
log ""

# Preflight: Docker daemon access
if ! docker info >/dev/null 2>&1; then
    fail_preflight "Docker daemon is not accessible. Run as root/sudo or ensure Docker permissions are configured."
fi
log "✓ Docker daemon is accessible"

# Preflight: production DB container must be running for validation-phase comparisons
if ! docker inspect "$POSTGRES_DB_CONTAINER" >/dev/null 2>&1 || \
   [[ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_DB_CONTAINER" 2>/dev/null)" != "true" ]]; then
    fail_preflight "Production DB container '${POSTGRES_DB_CONTAINER}' is not running. Cannot compare restored data against production."
fi
log "✓ Production DB container '${POSTGRES_DB_CONTAINER}' is running"

# Resolve postgres UID/GID from production container for host bind mount ownership
POSTGRES_UID=$(docker exec "$POSTGRES_DB_CONTAINER" id -u postgres 2>/dev/null | xargs || true)
POSTGRES_GID=$(docker exec "$POSTGRES_DB_CONTAINER" id -g postgres 2>/dev/null | xargs || true)
if [[ ! "$POSTGRES_UID" =~ ^[0-9]+$ ]] || [[ ! "$POSTGRES_GID" =~ ^[0-9]+$ ]]; then
    fail_preflight "Could not determine postgres uid/gid from production container '${POSTGRES_DB_CONTAINER}'."
fi
log "✓ Detected postgres uid:gid = ${POSTGRES_UID}:${POSTGRES_GID}"

# Preflight: restore image must exist locally
if ! docker image inspect "$DB_IMAGE" >/dev/null 2>&1; then
    fail_preflight "Restore image '${DB_IMAGE}' not found locally. Build/pull the image before running restore tests."
fi
log "✓ Restore image '${DB_IMAGE}' is available"

# Preflight: required configuration files must exist
required_files=(
    "${DB_DIR}/pgbackrest.conf"
    "${DB_DIR}/postgresql.conf"
    "${DB_DIR}/pgbackrest-wrapper.sh"
    "${SECRETS_DIR}/aws.env"
)
for required_file in "${required_files[@]}"; do
    if [[ ! -f "$required_file" ]]; then
        fail_preflight "Required file missing: ${required_file}"
    fi
done
log "✓ Required config and secret files exist"

# Preflight: port 5433 must be free
if command -v ss >/dev/null 2>&1; then
    if ss -tln "( sport = :${RESTORE_PORT} )" 2>/dev/null | grep -q ":${RESTORE_PORT}"; then
        fail_preflight "Port ${RESTORE_PORT} is already in use. Stop the conflicting service/container first."
    fi
elif command -v netstat >/dev/null 2>&1; then
    if netstat -tln 2>/dev/null | awk '{print $4}' | grep -E "(^|:)${RESTORE_PORT}$" >/dev/null; then
        fail_preflight "Port ${RESTORE_PORT} is already in use. Stop the conflicting service/container first."
    fi
else
    log "WARNING: Could not verify port ${RESTORE_PORT} availability (no ss/netstat installed)"
fi
log "✓ Port ${RESTORE_PORT} is available"

# Preflight: temp directory parent must be writable
temp_parent="$(dirname "$TEMP_DIR")"
if [[ ! -w "$temp_parent" ]]; then
    fail_preflight "Temporary directory parent '${temp_parent}' is not writable."
fi
log "✓ Temporary directory parent '${temp_parent}' is writable"

# Preflight: validation targets must exist in production and contain user tables
for validate_db in "${VALIDATE_DBS[@]}"; do
    if [[ "$(psql_prod postgres "SELECT 1 FROM pg_database WHERE datname='${validate_db}';" 2>/dev/null | xargs || true)" != "1" ]]; then
        fail_preflight "Validation database '${validate_db}' does not exist in production container '${POSTGRES_DB_CONTAINER}'."
    fi

    db_table_count=$(psql_prod "$validate_db" "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');" 2>/dev/null | xargs || echo "0")
    if [[ "$db_table_count" =~ ^[0-9]+$ ]] && [[ "$db_table_count" -eq 0 ]]; then
        fail_preflight "Validation database '${validate_db}' has no user tables in production."
    fi
    if [[ ! "$db_table_count" =~ ^[0-9]+$ ]]; then
        fail_preflight "Could not determine user table count in production database '${validate_db}'."
    fi

    log "✓ Validation target confirmed: ${validate_db} (${db_table_count} user tables)"
done
log ""

# Pre-run cleanup: remove any leftovers from a previous failed run
if docker inspect "$RESTORE_CONTAINER" >/dev/null 2>&1; then
    log "WARNING: Found leftover container '${RESTORE_CONTAINER}' — removing before starting"
    docker stop "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
    docker rm   "$RESTORE_CONTAINER" >/dev/null 2>&1 || true
fi
if [[ -d "$TEMP_DIR" ]]; then
    log "WARNING: Found leftover temp directory '${TEMP_DIR}' — removing before starting"
    rm -rf "$TEMP_DIR"
fi

# Load secrets
log "Loading secrets..."
source "${SECRETS_DIR}/aws.env"
log "✓ Secrets loaded"
log ""

# ─── Restore phase ───────────────────────────────────────────────────────────

if ! run_restore_phase; then
    log ""
    log "=== PostgreSQL Restore Test FAILED ==="
    send_restore_report
    exit $EXIT_ERROR
fi

# ─── Validation phase ────────────────────────────────────────────────────────

if ! run_validation_phase; then
    log ""
    log "=== PostgreSQL Restore Test FAILED ==="
    send_restore_report
    exit $EXIT_ERROR
fi

# ─── All passed ──────────────────────────────────────────────────────────────

OVERALL_RESULT="PASSED"
log ""
log "=== PostgreSQL Restore Test PASSED ==="
log "Restore duration: $(format_duration $RESTORE_DURATION)"
log "Total duration:   $(format_duration $(( $(date +%s) - START_TIME )))"
send_restore_report
exit $EXIT_SUCCESS
