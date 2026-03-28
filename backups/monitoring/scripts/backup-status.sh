#!/bin/bash
# Backup Status Monitor
# Orchestrates PostgreSQL and Foundry backup status checks
# Reports to console and Discord

set -euo pipefail

# Determine script and backup directories using realpath (Issue 4)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")" 
MONITORING_DIR="$(realpath "$SCRIPT_DIR/..")"
BACKUPS_DIR="$(realpath "$MONITORING_DIR/..")"
STACK_DIR="$(realpath "$BACKUPS_DIR/..")"
SECRETS_DIR="${BACKUPS_DIR}/secrets"
DISCORD_ENV="${SECRETS_DIR}/discord.env"

# Load centralized configuration (Issue 3)
source "${BACKUPS_DIR}/config.sh"

# Check required dependencies (Issue 4)
for cmd in docker jq bc date curl restic aws; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: Required command '$cmd' is not installed" >&2
        exit 1
    fi
done

# Load Discord webhook if available
if [[ -f "$DISCORD_ENV" ]]; then
    source "$DISCORD_ENV"
fi

# Validate and load shared libraries (Issue 5)
for lib in "discord-lib.sh" "check-postgres-backup.sh" "check-foundry-backup.sh" "check-logs-backup.sh" "check-configs-backup.sh" "check-restore-test.sh"; do
    lib_path="${SCRIPT_DIR}/${lib}"
    if [[ ! -f "$lib_path" ]]; then
        echo "ERROR: Required library '$lib' not found at $lib_path" >&2
        exit 1
    fi
    source "$lib_path"
done

# Set configuration for sub-modules (now using values from config.sh)
export FOUNDRY_AWS_ENV="${SECRETS_DIR}/aws.env"
export FOUNDRY_RESTIC_KEY="${SECRETS_DIR}/restic.key"
export LOGS_AWS_ENV="${SECRETS_DIR}/aws.env"
export CONFIGS_AWS_ENV="${SECRETS_DIR}/aws.env"
export CONFIGS_RESTIC_KEY="${SECRETS_DIR}/restic.key"

# get_most_recent_log
#
# Gets the most recent log file for a given backup type
#
# Arguments:
#   $1 - Log directory path
#   $2 - Log prefix (e.g., "backup", "diff-backup", "full-backup")
#
# Returns:
#   Path to most recent log file, or empty string if none found
get_most_recent_log() {
    local log_dir="$1"
    local log_prefix="$2"
    
    if [[ ! -d "$log_dir" ]]; then
        return 1
    fi
    
    # Find most recent log file matching pattern
    local log_file
    log_file=$(find "$log_dir" -maxdepth 1 -name "${log_prefix}-*.log" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    
    if [[ -n "$log_file" ]] && [[ -f "$log_file" ]]; then
        echo "$log_file"
        return 0
    fi
    
    return 1
}

# check_for_timeout_in_log
#
# Checks if the most recent backup run timed out
#
# Arguments:
#   $1 - LOG_FILE path to check
#
# Returns:
#   0 if timeout detected, 1 if no timeout
#
# Output:
#   Prints timeout message if found
check_for_timeout_in_log() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        return 1
    fi
    
    # Check for timeout marker in last 50 lines
    if tail -50 "$log_file" 2>/dev/null | grep -q "⏱ TIMEOUT:"; then
        # Extract the timeout message
        tail -50 "$log_file" | grep "⏱ TIMEOUT:" | tail -1
        return 0
    fi
    
    return 1
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# error
#
# Logs an error message to stderr
#
# Arguments:
#   $* - Error message
error() {
    echo "ERROR: $*" >&2
}

# warning
#
# Logs a warning message to stderr  
#
# Arguments:
#   $* - Warning message
warning() {
    echo "WARNING: $*" >&2
}

# validate_numeric
#
# Validates that a value is numeric and within reasonable range for timestamps
#
# Arguments:
#   $1 - Value to validate
#   $2 - Variable name (for error messages)
#
# Returns:
#   0 if valid, 1 if invalid
#   Error/warning messages on stderr
validate_numeric() {
    local value="$1"
    local name="$2"
    
    if [[ -z "$value" ]] || [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Invalid numeric value for ${name}: '${value}'" >&2
        return 1
    fi
    
    # Sanity check: timestamp shouldn't be in the future or too far in the past
    if [[ "$name" =~ time|Time|TIME ]]; then
        local now=$(date +%s)
        local two_years_ago=$((now - 63072000))  # ~2 years
        local one_hour_future=$((now + 3600))
        
        if ((value > one_hour_future)); then
            echo "WARNING: Timestamp ${name} is in the future: ${value}" >&2
            return 1
        elif ((value < two_years_ago)); then
            echo "WARNING: Timestamp ${name} is more than 2 years old: ${value}" >&2
            return 1
        fi
    fi
    
    return 0
}

# format_bytes
#
# Formats bytes into human-readable size string
#
# Arguments:
#   $1 - Size in bytes
#
# Returns:
#   Formatted string (e.g., "1.50GB", "512.00MB", "42B")
format_bytes() {
    local bytes="${1:-0}"
    
    # Validate input (Issue 9, 20, 15)
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        echo "WARNING: format_bytes received invalid input: '${bytes}', defaulting to 0B" >&2
        echo "0B"
        return 0
    fi
    
    if ((bytes < 1024)); then
        echo "${bytes}B"
    elif ((bytes < 1048576)); then
        printf "%.2fKB" "$(echo "$bytes/1024" | bc -l)"
    elif ((bytes < 1073741824)); then
        printf "%.2fMB" "$(echo "$bytes/1048576" | bc -l)"
    else
        printf "%.2fGB" "$(echo "$bytes/1073741824" | bc -l)"
    fi
}

# get_consolidated_success_stats
#
# Calculates 30-day consolidated backup run success metrics from wrapper log files.
#
# Globals Set:
#   CONSOLIDATED_RUNS_30D - Total runs in the last 30 days
#   CONSOLIDATED_SUCCESS_30D - Successful runs in the last 30 days
#   CONSOLIDATED_FAILED_30D - Failed runs in the last 30 days
#   CONSOLIDATED_UNKNOWN_30D - Runs without final status marker
#   CONSOLIDATED_SUCCESS_RATE_30D - Success percentage (0.0-100.0)
get_consolidated_success_stats() {
    local consolidated_log_dir="${STACK_DIR}/logs/backups/consolidated"
    local cutoff_epoch
    cutoff_epoch=$(date -d '30 days ago' +%s)

    CONSOLIDATED_RUNS_30D=0
    CONSOLIDATED_SUCCESS_30D=0
    CONSOLIDATED_FAILED_30D=0
    CONSOLIDATED_UNKNOWN_30D=0
    CONSOLIDATED_SUCCESS_RATE_30D="0.0"

    if [[ ! -d "$consolidated_log_dir" ]]; then
        return 0
    fi

    local log_file
    for log_file in "$consolidated_log_dir"/run-*.log; do
        if [[ ! -f "$log_file" ]]; then
            continue
        fi

        local basename log_date file_epoch
        basename=$(basename "$log_file")
        log_date="${basename#run-}"
        log_date="${log_date%.log}"

        if ! file_epoch=$(date -d "$log_date" +%s 2>/dev/null); then
            continue
        fi

        if ((file_epoch < cutoff_epoch)); then
            continue
        fi

        ((CONSOLIDATED_RUNS_30D += 1))

        if grep -q "Consolidated backup run completed successfully" "$log_file"; then
            ((CONSOLIDATED_SUCCESS_30D += 1))
        elif grep -q "Consolidated backup run completed with failures" "$log_file"; then
            ((CONSOLIDATED_FAILED_30D += 1))
        else
            ((CONSOLIDATED_UNKNOWN_30D += 1))
        fi
    done

    if ((CONSOLIDATED_RUNS_30D > 0)); then
        CONSOLIDATED_SUCCESS_RATE_30D=$(awk "BEGIN {printf \"%.1f\", (${CONSOLIDATED_SUCCESS_30D} / ${CONSOLIDATED_RUNS_30D}) * 100}")
    fi
}

# Main status check - console output
main() {
    echo -e "${BLUE}=== Backup Status ===${NC}\n"
    
    local pg_status=0
    local foundry_status=0
    local logs_status=0
    local configs_status=0
    local restore_test_status=0
    
    # PostgreSQL Backup Status
    local pg_info
    if ! pg_info=$(validate_postgres_backup_system 2>&1); then
        echo -e "${RED}✗ PostgreSQL backup system validation failed${NC}"
        echo -e "${RED}${pg_info}${NC}"
        pg_status=1
    else
        if ! display_postgres_status "$pg_info"; then
            pg_status=1
        fi
    fi
    
    # Foundry Backup Status
    if ! display_foundry_status; then
        foundry_status=1
    fi

    # Logs Backup Status
    if ! display_logs_status; then
        logs_status=1
    fi

    # Configs Backup Status
    if ! display_configs_status; then
        configs_status=1
    fi

    # Restore Test Status
    if ! display_restore_test_status; then
        restore_test_status=1
    fi

    # 30-day consolidated success rate (subset scope)
    get_consolidated_success_stats
    echo -e "\n${BLUE}=== Consolidated Reliability (30d, Subset Scope) ===${NC}"
    echo -e "${BLUE}    Scope:${NC} Consolidated run only (PostgreSQL -> Foundry -> Docker logs export -> Logs S3 -> Configs S3)"
    echo -e "${BLUE}    Excludes:${NC} Standalone timers/services (e.g., heartbeat + log-archive timers)"
    if ((CONSOLIDATED_RUNS_30D > 0)); then
        echo -e "${GREEN}✓ Success Rate:${NC}      ${CONSOLIDATED_SUCCESS_RATE_30D}% (${CONSOLIDATED_SUCCESS_30D}/${CONSOLIDATED_RUNS_30D})"
        echo -e "${GREEN}✓ Failed Runs:${NC}       ${CONSOLIDATED_FAILED_30D}"
        if ((CONSOLIDATED_UNKNOWN_30D > 0)); then
            echo -e "${YELLOW}⚠ Unknown Outcomes:${NC}  ${CONSOLIDATED_UNKNOWN_30D}"
        fi
    else
        echo -e "${YELLOW}⚠ No consolidated run logs found for the last 30 days${NC}"
    fi
    
    # Overall status - Issue 17
    if ((pg_status == 0)) && ((foundry_status == 0)) && ((logs_status == 0)) && ((configs_status == 0)) && ((restore_test_status == 0)); then
        echo -e "\n${GREEN}✓ All backup systems operational${NC}"
        return $EXIT_SUCCESS
    elif ((pg_status == 2)) || ((foundry_status == 2)) || ((logs_status == 2)) || ((configs_status == 2)) || ((restore_test_status == 2)); then
        echo -e "\n${RED}✗ Critical backup system errors detected${NC}"
        return $EXIT_ERROR
    else
        echo -e "\n${YELLOW}⚠ Some backup checks have warnings${NC}"
        return $EXIT_WARNING
    fi
}

# Daily heartbeat function - Discord notification
heartbeat() {
    echo "Sending daily backup heartbeat to Discord..."
    
    # Declare all variables at function scope (Issue 18, 19)
    local pg_info
    local foundry_check_result=0  # Issue 1,10: Use consistent 0=success convention
    local logs_check_result=0
    local configs_check_result=0
    local restore_test_check_result=0
    local now
    now=$(date +%s)
    local exit_code=$EXIT_SUCCESS  # Track overall exit code - Issue 17
    
    # Check PostgreSQL backups with timeout - Issue 2,3
    # Use a wrapper function to properly handle timeout and exit codes
    local pg_timeout_exit=0
    pg_info=$(timeout $COMMAND_TIMEOUT bash -c '
        source "'"$SCRIPT_DIR"'/check-postgres-backup.sh" || exit 1
        export POSTGRES_DB_CONTAINER="'"$POSTGRES_DB_CONTAINER"'"
        export POSTGRES_STANZA="'"$POSTGRES_STANZA"'"
        validate_postgres_backup_system
        exit $?
    ' 2>&1) || pg_timeout_exit=$?
    
    if ((pg_timeout_exit != 0)); then
        local error_prefix="PostgreSQL backup system validation failed"
        if ((pg_timeout_exit == 124)); then
            error_prefix="PostgreSQL backup check TIMED OUT after ${COMMAND_TIMEOUT}s"
        fi
        local error_msg="${error_prefix}.\n\n**Error:** ${pg_info}\n\n"
        error_msg+="**Container:** ${POSTGRES_DB_CONTAINER}\n"
        error_msg+="**Stanza:** ${POSTGRES_STANZA}\n\n"
        error_msg+="**Debug Steps:**\n"
        error_msg+="1. Check container: \`docker ps | grep ${POSTGRES_DB_CONTAINER}\`\n"
        error_msg+="2. Check pgBackRest: \`docker exec ${POSTGRES_DB_CONTAINER} pgbackrest info\`\n"
        error_msg+="3. Review logs: \`docker logs ${POSTGRES_DB_CONTAINER} --tail 100\`"
        
        if ! send_discord "Daily Heartbeat: Critical System Error" "$error_msg" 15548997 "🚨"; then
            echo "ERROR: Failed to send Discord notification" >&2
        fi
        return $EXIT_ERROR  # Issue 17: Critical error
    fi
    
    get_postgres_backup_stats "$pg_info"
    
    # Validate critical PostgreSQL variables are set (Issue 1, 4, 8, 11)
    if ! validate_numeric "${PG_LAST_BACKUP_TIME:-}" "PG_LAST_BACKUP_TIME"; then
        local error_msg="Failed to retrieve valid PostgreSQL backup timestamp.\n\n"
        error_msg+="**Debug Steps:**\n"
        error_msg+="1. Check info output: \`docker exec ${POSTGRES_DB_CONTAINER} pgbackrest info --stanza=${POSTGRES_STANZA}\`\n"
        error_msg+="2. Verify backups exist in repository"
        
        if ! send_discord "Daily Heartbeat: Data Error" "$error_msg" 15548997 "🚨"; then
            echo "ERROR: Failed to send Discord notification" >&2
        fi
        return $EXIT_ERROR
    fi
    
    # Validate backup type is set - Issue 4
    if [[ -z "${PG_LAST_BACKUP_TYPE:-}" ]]; then
        echo "ERROR: PG_LAST_BACKUP_TYPE is not set" >&2
        if ! send_discord "Daily Heartbeat: Data Error" \
            "PostgreSQL backup type information missing." \
            15548997 "🚨"; then
            echo "ERROR: Failed to send Discord notification" >&2
        fi
        return $EXIT_ERROR
    fi
    
    # Check Foundry backups - call function directly for better performance
    # The timeout wrapper with bash -c adds ~58 seconds of overhead
    local foundry_info
    if foundry_info=$(validate_foundry_backup_system 2>&1); then
        # Parse the JSON response to set variables
        get_foundry_backup_stats "$foundry_info"
    else
        foundry_check_result=1  # Error occurred
        # Log the actual error for debugging
        echo "ERROR: Foundry backup check failed" >&2
        echo "Error output: ${foundry_info}" >&2
    fi

    # Check Logs backups
    local logs_info
    if logs_info=$(validate_logs_backup_system 2>&1); then
        get_logs_backup_stats "$logs_info"
    else
        logs_check_result=1
        echo "ERROR: Logs backup check failed" >&2
        echo "Error output: ${logs_info}" >&2
    fi

    # Check Configs backups
    local configs_info
    if configs_info=$(validate_configs_backup_system 2>&1); then
        get_configs_backup_stats "$configs_info"
    else
        configs_check_result=1
        echo "ERROR: Configs backup check failed" >&2
        echo "Error output: ${configs_info}" >&2
    fi

    # Check Restore Test status
    local restore_test_info
    if restore_test_info=$(validate_restore_test_system 2>&1); then
        get_restore_test_stats "$restore_test_info"
    else
        restore_test_check_result=1
        echo "ERROR: Restore-test check failed" >&2
        echo "Error output: ${restore_test_info}" >&2
    fi

    # Robust differential backup check using timestamp (Issue 1, 2, 3, 5, 8)
    # Check if last diff backup is too old, accounting for Sunday (no diff runs on Sunday)
    local diff_backup_status=0  # Issue 1: 0=success, 1=error
    
    # On Sunday, diff backup from Saturday might be ~30 hours old; on other days, should be <36 hours
    local max_diff_age=$MAX_DIFF_BACKUP_AGE
    if [[ $(date +%u) -eq 7 ]]; then
        # Sunday: Allow extra time since diff ran Saturday night
        max_diff_age=$((MAX_DIFF_BACKUP_AGE + 14400))  # Add 4 hours buffer
    fi
    
    # Always check diff backup age, even on Sunday - Issue 2
    if [[ -n "${PG_LAST_DIFF_TIME:-}" ]] && validate_numeric "${PG_LAST_DIFF_TIME}" "PG_LAST_DIFF_TIME" 2>/dev/null; then
        local diff_age=$((now - PG_LAST_DIFF_TIME))
        if ((diff_age >= max_diff_age)); then
            diff_backup_status=1  # Error - diff backup too old
        fi
    else
        # No valid diff backup found
        diff_backup_status=1
    fi
    
    # Validate critical variables are set (Issue 1, 4, 9, 11)
    if ! validate_numeric "${PG_OLDEST_BACKUP_TIME:-}" "PG_OLDEST_BACKUP_TIME"; then
        local error_msg="Invalid PostgreSQL oldest backup timestamp: ${PG_OLDEST_BACKUP_TIME:-unset}"
        if ! send_discord "Daily Heartbeat: Data Error" "$error_msg" 15548997 "🚨"; then
            echo "ERROR: Failed to send Discord notification" >&2
        fi
        return $EXIT_ERROR
    fi
    
    # Format data for Discord with validated inputs (Issue 1, 9)
    local formatted_time=$(date -d "@${PG_LAST_BACKUP_TIME}" '+%Y-%m-%d %H:%M:%S')
    local formatted_size=$(format_bytes "${PG_LAST_BACKUP_SIZE:-0}")
    local pitr_from=$(date -d "@${PG_OLDEST_BACKUP_TIME}" '+%Y-%m-%d %H:%M:%S')
    
    # Format PITR end time based on whether WAL extends beyond backup (Issue 1, 11)
    local pitr_to
    local pitr_type
    if [[ "${PG_PITR_EXTENDS_VIA_WAL:-false}" == "true" ]]; then
        if validate_numeric "${PG_PITR_END_TIME:-}" "PG_PITR_END_TIME" 2>/dev/null; then
            pitr_to=$(date -d "@${PG_PITR_END_TIME}" '+%Y-%m-%d %H:%M:%S')
            pitr_type=" (via WAL)"
        else
            # Invalid PITR time, fall back to backup time
            echo "WARNING: PG_PITR_EXTENDS_VIA_WAL is true but PG_PITR_END_TIME is invalid, falling back to backup time" >&2
            pitr_to=$(date -d "@${PG_LAST_BACKUP_TIME}" '+%Y-%m-%d %H:%M:%S')
            pitr_type=""
        fi
    else
        pitr_to=$(date -d "@${PG_LAST_BACKUP_TIME}" '+%Y-%m-%d %H:%M:%S')
        pitr_type=""
    fi
    
    # Robust full backup check using timestamp (Issue 1, 3, 5, 8, 11)
    # Check if last full backup is recent (within 8 days for weekly schedule with buffer)
    local full_backup_status=0  # Issue 1: 0=success, 1=error
    
    if [[ -n "${PG_LAST_FULL_TIME:-}" ]] && validate_numeric "${PG_LAST_FULL_TIME}" "PG_LAST_FULL_TIME" 2>/dev/null; then
        local full_age=$((now - PG_LAST_FULL_TIME))
        if ((full_age >= MAX_FULL_BACKUP_AGE)); then
            full_backup_status=1  # Error - full backup too old
        fi
    else
        # No valid full backup found
        full_backup_status=1
    fi

    # Build status message using array for better maintainability - Issue 16
    local status_lines=()
    status_lines+=("**PostgreSQL (pgBackRest)**")
    status_lines+=("✓ Last backup: \`${formatted_time}\`")
    status_lines+=("✓ Type: \`${PG_LAST_BACKUP_TYPE}\`")
    status_lines+=("✓ Size: \`${formatted_size}\`")
    status_lines+=("✓ PITR Range: \`${pitr_from}\` → \`${pitr_to}\`${pitr_type}")
    
    # WAL Archive health - check for failures in past 7 days (Issue 1, 8, 9, 11)
    local wal_health_icon="✓"
    local wal_health_msg=""
    
    # Validate all WAL-related variables before arithmetic (Issue 1, 11)
    if [[ -n "${PG_WAL_FAILED_COUNT:-}" ]] && validate_numeric "${PG_WAL_FAILED_COUNT}" "PG_WAL_FAILED_COUNT" 2>/dev/null && \
       ((PG_WAL_FAILED_COUNT > 0)) && \
       [[ -n "${PG_WAL_LAST_FAILED_AGE:-}" ]] && validate_numeric "${PG_WAL_LAST_FAILED_AGE}" "PG_WAL_LAST_FAILED_AGE" 2>/dev/null && \
       ((PG_WAL_LAST_FAILED_AGE < WAL_FAILURE_WINDOW)); then
        # Failures detected in past 7 days
        wal_health_icon="⚠"
        local failed_days=$((PG_WAL_LAST_FAILED_AGE / 86400))
        if ((failed_days > 0)); then
            wal_health_msg="${PG_WAL_FAILED_COUNT} failures in past 7 days (last ${failed_days}d ago)"
        else
            local failed_hours=$((PG_WAL_LAST_FAILED_AGE / 3600))
            wal_health_msg="${PG_WAL_FAILED_COUNT} failures in past 7 days (last ${failed_hours}h ago)"
        fi
    else
        # All good - show last archive time (Issue 9, 11)
        if [[ -n "${PG_WAL_LAST_ARCHIVED_TIME:-}" ]] && \
           validate_numeric "${PG_WAL_LAST_ARCHIVED_TIME}" "PG_WAL_LAST_ARCHIVED_TIME" 2>/dev/null; then
            local wal_archived_time=$(date -d "@${PG_WAL_LAST_ARCHIVED_TIME}" '+%Y-%m-%d %H:%M:%S')
            wal_health_msg="OK (last: \`${wal_archived_time}\`)"
        else
            wal_health_msg="OK"
        fi
    fi
    
    status_lines+=("${wal_health_icon} WAL Archive: ${wal_health_msg}")
    
    # Add oldest backup info with enhanced pruning status - Issue 11,12,16
    local pg_oldest_age_days=$(( (now - PG_OLDEST_BACKUP_TIME) / 86400 ))
    local pg_oldest_time=$(date -d "@${PG_OLDEST_BACKUP_TIME}" '+%Y-%m-%d %H:%M:%S')
    
    # Enhanced pruning status with multiple states - Issue 12
    case "${PG_PRUNING_STATUS:-Healthy}" in
        Critical)
            status_lines+=("✗ Oldest backup: \`${pg_oldest_time}\` (${pg_oldest_age_days} days - CRITICAL: ${PG_PRUNING_MESSAGE:-pruning failed})")
            exit_code=$EXIT_ERROR
            ;;
        Warning)
            status_lines+=("⚠ Oldest backup: \`${pg_oldest_time}\` (${pg_oldest_age_days} days - ${PG_PRUNING_MESSAGE:-check pruning})")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_WARNING
            ;;
        *)
            status_lines+=("✓ Oldest backup: \`${pg_oldest_time}\` (${pg_oldest_age_days} days)")
            ;;
    esac
    
    status_lines+=("✓ Total backups: \`${PG_BACKUP_COUNT}\`")
    
    # Add Foundry status with proper validation - Issue 1,4,7,8,10,11,16
    status_lines+=("")
    status_lines+=("**Foundry VTT (restic)**")
    
    if ((foundry_check_result == 0)) && [[ -n "${FOUNDRY_SNAPSHOT_TIME:-}" ]] && \
       validate_numeric "${FOUNDRY_SNAPSHOT_TIME}" "FOUNDRY_SNAPSHOT_TIME" 2>/dev/null; then
        local foundry_time=$(date -d "@${FOUNDRY_SNAPSHOT_TIME}" '+%Y-%m-%d %H:%M:%S')
        local foundry_size=$(format_bytes "${FOUNDRY_SNAPSHOT_SIZE:-0}")
        
        # Validate age hours - Issue 4,11
        local age_display="${FOUNDRY_AGE_HOURS:-unknown}h"
        if [[ -n "${FOUNDRY_AGE_HOURS:-}" ]] && [[ "${FOUNDRY_AGE_HOURS}" =~ ^[0-9]+$ ]]; then
            age_display="${FOUNDRY_AGE_HOURS}h ago"
        fi
        
        status_lines+=("✓ Last backup: \`${foundry_time}\` (${age_display})")
        status_lines+=("✓ Size: \`${foundry_size}\`")
        
        # Add oldest backup info if available (Issue 1,11,12)
        if [[ -n "${FOUNDRY_OLDEST_SNAPSHOT_TIME:-}" ]] && \
           validate_numeric "${FOUNDRY_OLDEST_SNAPSHOT_TIME}" "FOUNDRY_OLDEST_SNAPSHOT_TIME" 2>/dev/null; then
            local foundry_oldest_age_days=$(( (now - FOUNDRY_OLDEST_SNAPSHOT_TIME) / 86400 ))
            local foundry_oldest_time=$(date -d "@${FOUNDRY_OLDEST_SNAPSHOT_TIME}" '+%Y-%m-%d %H:%M:%S')
            
            case "${FOUNDRY_PRUNING_STATUS:-Healthy}" in
                Critical)
                    status_lines+=("✗ Oldest backup: \`${foundry_oldest_time}\` (${foundry_oldest_age_days} days - CRITICAL: ${FOUNDRY_PRUNING_MESSAGE:-pruning failed})")
                    exit_code=$EXIT_ERROR
                    ;;
                Warning)
                    status_lines+=("⚠ Oldest backup: \`${foundry_oldest_time}\` (${foundry_oldest_age_days} days - ${FOUNDRY_PRUNING_MESSAGE:-check pruning})")
                    [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_WARNING
                    ;;
                *)
                    status_lines+=("✓ Oldest backup: \`${foundry_oldest_time}\` (${foundry_oldest_age_days} days)")
                    ;;
            esac
        fi
    else
        status_lines+=("✗ Failed to retrieve backup information")
        # Include the actual error message for debugging
        if [[ -n "${foundry_info:-}" ]]; then
            # Sanitize and truncate error message for Discord (avoid exceeding limits)
            local error_preview="${foundry_info:0:500}"
            status_lines+=("**Error:** \`${error_preview}\`")
        fi
        status_lines+=("**Debug:** Check restic repo: \`restic -r ${FOUNDRY_RESTIC_REPO} snapshots\`")
        exit_code=$EXIT_ERROR
    fi
    
    # Add Logs status
    status_lines+=("")
    status_lines+=("**Logs (s3 sync)**")

    if ((logs_check_result == 0)) && [[ -n "${LOGS_SYNC_TIME:-}" ]]; then
        local logs_age_display="${LOGS_AGE_HOURS:-unknown}h"
        if [[ -n "${LOGS_AGE_HOURS:-}" ]] && [[ "${LOGS_AGE_HOURS}" =~ ^[0-9]+$ ]]; then
            logs_age_display="${LOGS_AGE_HOURS}h ago"
        fi

        status_lines+=("✓ Last sync: \`${LOGS_SYNC_TIME}\` (${logs_age_display})")
        status_lines+=("✓ S3 files: \`${LOGS_S3_FILES:-unknown}\`")
        status_lines+=("✓ S3 size: \`$(format_bytes "${LOGS_S3_SIZE:-0}")\`")
    else
        status_lines+=("✗ Failed to retrieve backup information")
        if [[ -n "${logs_info:-}" ]]; then
            local logs_error_preview="${logs_info:0:500}"
            status_lines+=("**Error:** \`${logs_error_preview}\`")
        fi
        status_lines+=("**Debug:** Check S3: \`aws s3 ls ${LOGS_S3_PATH}/\`")
        exit_code=$EXIT_ERROR
    fi

    # Add Configs status
    status_lines+=("")
    status_lines+=("**Configs (restic)**")

    if ((configs_check_result == 0)) && [[ -n "${CONFIGS_SNAPSHOT_TIME:-}" ]] && \
       validate_numeric "${CONFIGS_SNAPSHOT_TIME}" "CONFIGS_SNAPSHOT_TIME" 2>/dev/null; then
        local configs_time=$(date -d "@${CONFIGS_SNAPSHOT_TIME}" '+%Y-%m-%d %H:%M:%S')
        local configs_size=$(format_bytes "${CONFIGS_SNAPSHOT_SIZE:-0}")

        local configs_age_display="${CONFIGS_AGE_HOURS:-unknown}h"
        if [[ -n "${CONFIGS_AGE_HOURS:-}" ]] && [[ "${CONFIGS_AGE_HOURS}" =~ ^[0-9]+$ ]]; then
            configs_age_display="${CONFIGS_AGE_HOURS}h ago"
        fi

        status_lines+=("✓ Last backup: \`${configs_time}\` (${configs_age_display})")
        local configs_file_display="${CONFIGS_SNAPSHOT_FILES:-unknown}"
        if [[ -n "${CONFIGS_FILE_DELTA:-}" ]] && [[ "${CONFIGS_FILE_DELTA}" =~ ^-?[0-9]+$ ]] && [[ "${CONFIGS_FILE_DELTA}" != "0" ]]; then
            if [[ "${CONFIGS_FILE_DELTA}" -gt 0 ]]; then
                configs_file_display="${CONFIGS_SNAPSHOT_FILES:-unknown} (+${CONFIGS_FILE_DELTA})"
            else
                configs_file_display="${CONFIGS_SNAPSHOT_FILES:-unknown} (${CONFIGS_FILE_DELTA})"
            fi
        fi
        status_lines+=("✓ Files: \`${configs_file_display}\`")
        status_lines+=("✓ Size: \`${configs_size}\`")
        status_lines+=("✓ Snapshots: \`${CONFIGS_TOTAL_SNAPSHOTS:-unknown}\` (30 daily + monthly forever)")
    else
        status_lines+=("✗ Failed to retrieve backup information")
        if [[ -n "${configs_info:-}" ]]; then
            local configs_error_preview="${configs_info:0:500}"
            status_lines+=("**Error:** \`${configs_error_preview}\`")
        fi
        status_lines+=("**Debug:** Check restic repo: \`restic -r ${CONFIGS_RESTIC_REPO} snapshots\`")
        exit_code=$EXIT_ERROR
    fi

    # Add Restore Test status
    status_lines+=("")
    status_lines+=("**Restore Test (monthly)**")

    if ((restore_test_check_result == 0)) && [[ -n "${RESTORE_TEST_RUN_TIME:-}" ]]; then
        status_lines+=("✓ Last run: \`${RESTORE_TEST_RUN_TIME}\`")
        status_lines+=("✓ Result: \`${RESTORE_TEST_RESULT:-unknown}\` (${RESTORE_TEST_PASSED_CHECKS:-0}/${RESTORE_TEST_TOTAL_CHECKS:-0} checks)")
        status_lines+=("✓ Duration: \`${RESTORE_TEST_DURATION:-unknown}\`")
        status_lines+=("✓ Age: \`${RESTORE_TEST_AGE_DAYS:-unknown} days\`")
        status_lines+=("✓ State log: \`${RESTORE_TEST_STATE_LOG_FILE:-unknown}\`")
    else
        status_lines+=("✗ Failed to retrieve restore-test information")
        if [[ -n "${restore_test_info:-}" ]]; then
            local restore_error_preview="${restore_test_info:0:500}"
            status_lines+=("**Error:** \`${restore_error_preview}\`")
        fi
        status_lines+=("**Debug:** Check restore-test logs: \`ls -la ${STACK_DIR}/logs/restore/orchestration/\`")
        exit_code=$EXIT_ERROR
    fi

    status_lines+=("")
    status_lines+=("**Storage**")
    status_lines+=("✓ S3 Repos: Operational")

    # 30-day consolidated success rate (subset scope)
    get_consolidated_success_stats
    status_lines+=("")
    status_lines+=("**Reliability (30d, subset scope)**")
    status_lines+=("Scope: Consolidated run only (PostgreSQL -> Foundry -> Docker logs export -> Logs S3 -> Configs S3)")
    status_lines+=("Excludes: Standalone timers/services (e.g., heartbeat + log-archive timers)")
    if ((CONSOLIDATED_RUNS_30D > 0)); then
        status_lines+=("✓ Consolidated success rate: \`${CONSOLIDATED_SUCCESS_RATE_30D}%\` (${CONSOLIDATED_SUCCESS_30D}/${CONSOLIDATED_RUNS_30D})")
        status_lines+=("✓ Failed runs: \`${CONSOLIDATED_FAILED_30D}\`")
        if ((CONSOLIDATED_UNKNOWN_30D > 0)); then
            status_lines+=("⚠ Unknown outcomes: \`${CONSOLIDATED_UNKNOWN_30D}\`")
        fi
    else
        status_lines+=("⚠ No consolidated run logs found in the last 30 days")
    fi
    
    # Check for specific issues - Issue 1,2,10,12,13
    local has_warnings=0
    local warning_lines=()
    
    # Check for timeout in PostgreSQL full backup
    local pg_full_log
    if pg_full_log=$(get_most_recent_log "${STACK_DIR}/logs/backups/postgres-full" "full-backup"); then
        if check_for_timeout_in_log "$pg_full_log"; then
            warning_lines+=("**TIMEOUT:** PostgreSQL full backup exceeded systemd timeout limit.")
            warning_lines+=("**Action:** Review logs: \`journalctl -u postgres-full-backup.service -n 100\`")
            warning_lines+=("**Action:** Consider increasing TimeoutStartSec in service file if backups are legitimately slow.")
            has_warnings=1
            exit_code=$EXIT_ERROR
        fi
    fi
    
    # Check for timeout in PostgreSQL diff backup
    local pg_diff_log
    if pg_diff_log=$(get_most_recent_log "${STACK_DIR}/logs/backups/postgres-diff" "diff-backup"); then
        if check_for_timeout_in_log "$pg_diff_log"; then
            warning_lines+=("**TIMEOUT:** PostgreSQL differential backup exceeded systemd timeout limit.")
            warning_lines+=("**Action:** Review logs: \`journalctl -u postgres-diff-backup.service -n 100\`")
            warning_lines+=("**Action:** Consider increasing TimeoutStartSec in service file if backups are legitimately slow.")
            has_warnings=1
            exit_code=$EXIT_ERROR
        fi
    fi
    
    # Check for timeout in Foundry backup
    local foundry_log
    if foundry_log=$(get_most_recent_log "${STACK_DIR}/logs/backups/foundry" "backup"); then
        if check_for_timeout_in_log "$foundry_log"; then
            warning_lines+=("**TIMEOUT:** Foundry backup exceeded systemd timeout limit.")
            warning_lines+=("**Action:** Review logs: \`journalctl -u foundry-backup.service -n 100\`")
            warning_lines+=("**Action:** Consider increasing TimeoutStartSec in service file if backups are legitimately slow.")
            has_warnings=1
            exit_code=$EXIT_ERROR
        fi
    fi

    # Check for timeout in Logs backup
    local logs_backup_log
    if logs_backup_log=$(get_most_recent_log "${STACK_DIR}/logs/backups/logs-backup" "backup"); then
        if check_for_timeout_in_log "$logs_backup_log"; then
            warning_lines+=("**TIMEOUT:** Logs backup exceeded systemd timeout limit.")
            warning_lines+=("**Action:** Review logs: \`journalctl -u logs-backup.service -n 100\`")
            warning_lines+=("**Action:** Consider increasing TimeoutStartSec in logs-backup.service if backups are legitimately slow.")
            has_warnings=1
            exit_code=$EXIT_ERROR
        fi
    fi

    # Check for timeout in Configs backup
    local configs_backup_log
    if configs_backup_log=$(get_most_recent_log "${STACK_DIR}/logs/backups/configs-backup" "backup"); then
        if check_for_timeout_in_log "$configs_backup_log"; then
            warning_lines+=("**TIMEOUT:** Configs backup exceeded systemd timeout limit.")
            warning_lines+=("**Action:** Review logs: \`journalctl -u configs-backup.service -n 100\`")
            warning_lines+=("**Action:** Consider increasing TimeoutStartSec in configs-backup.service if backups are legitimately slow.")
            has_warnings=1
            exit_code=$EXIT_ERROR
        fi
    fi

    # Check for timeout in Restore Test
    local restore_test_log
    if restore_test_log=$(get_most_recent_log "${STACK_DIR}/logs/restore/orchestration" "restore-test"); then
        if check_for_timeout_in_log "$restore_test_log"; then
            warning_lines+=("**TIMEOUT:** Restore test exceeded systemd timeout limit.")
            warning_lines+=("**Action:** Review logs: \`journalctl -u restore-test.service -n 100\`")
            warning_lines+=("**Action:** Consider increasing TimeoutStartSec in restore-test.service if needed.")
            has_warnings=1
            exit_code=$EXIT_ERROR
        fi
    fi
    
    # Check full backup status - Issue 1
    if ((full_backup_status != 0)); then
        warning_lines+=("**Warning:** PostgreSQL full backup is overdue (older than $((MAX_FULL_BACKUP_AGE / 86400)) days).")
        warning_lines+=("**Action:** Check systemd timer: \`systemctl status postgres-full-backup.timer\`")
        warning_lines+=("**Logs:** \`journalctl -u postgres-full-backup.service -n 50\`")
        has_warnings=1
        [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_WARNING
    fi
    
    # Check diff backup status - Issue 1,2
    if ((diff_backup_status != 0)); then
        local day_name=$(date +%A)
        warning_lines+=("**Warning:** Differential backup is overdue on ${day_name}.")
        warning_lines+=("**Action:** Check systemd timer: \`systemctl status postgres-diff-backup.timer\`")
        warning_lines+=("**Logs:** \`journalctl -u postgres-diff-backup.service -n 50\`")
        has_warnings=1
        [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_WARNING
    fi
    
    # Check Foundry backup - Issue 10,13
    if ((foundry_check_result != 0)) || \
       [[ -z "${FOUNDRY_SNAPSHOT_TIME:-}" ]] || \
       ! validate_numeric "${FOUNDRY_SNAPSHOT_TIME}" "FOUNDRY_SNAPSHOT_TIME" 2>/dev/null || \
       [[ "${FOUNDRY_STATUS:-}" == "Stale" ]]; then
        
        if ((foundry_check_result != 0)) || [[ -z "${FOUNDRY_SNAPSHOT_TIME:-}" ]]; then
            warning_lines+=("**Warning:** Foundry backup check failed or no backup data available.")
            warning_lines+=("**Action:** Check systemd timer: \`systemctl status foundry-backup.timer\`")
            warning_lines+=("**Logs:** \`journalctl -u foundry-backup.service -n 50\`")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_ERROR
        elif [[ "${FOUNDRY_STATUS:-}" == "Stale" ]]; then
            warning_lines+=("**Warning:** Foundry backup is stale (older than ${FOUNDRY_BACKUP_STALE_HOURS} hours).")
            warning_lines+=("**Action:** Verify backup schedule and check for failures.")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_WARNING
        fi
        has_warnings=1
    fi

    # Check Logs backup
    if ((logs_check_result != 0)) || \
       [[ -z "${LOGS_SYNC_TIME:-}" ]] || \
       [[ "${LOGS_STATUS:-}" == "Stale" ]]; then

        if ((logs_check_result != 0)) || [[ -z "${LOGS_SYNC_TIME:-}" ]]; then
            warning_lines+=("**Warning:** Logs backup check failed or no backup data available.")
            warning_lines+=("**Action:** Check systemd timer: \`systemctl status logs-backup.timer\`")
            warning_lines+=("**Logs:** \`journalctl -u logs-backup.service -n 50\`")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_ERROR
        elif [[ "${LOGS_STATUS:-}" == "Stale" ]]; then
            warning_lines+=("**Warning:** Logs backup is stale (older than ${LOGS_BACKUP_STALE_HOURS} hours).")
            warning_lines+=("**Action:** Verify backup schedule and check for failures.")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_WARNING
        fi
        has_warnings=1
    fi

    # Check Configs backup
    if ((configs_check_result != 0)) || \
       [[ -z "${CONFIGS_SNAPSHOT_TIME:-}" ]] || \
       ! validate_numeric "${CONFIGS_SNAPSHOT_TIME}" "CONFIGS_SNAPSHOT_TIME" 2>/dev/null || \
       [[ "${CONFIGS_STATUS:-}" == "Stale" ]]; then

        if ((configs_check_result != 0)) || [[ -z "${CONFIGS_SNAPSHOT_TIME:-}" ]]; then
            warning_lines+=("**Warning:** Configs backup check failed or no backup data available.")
            warning_lines+=("**Action:** Check systemd timer: \`systemctl status configs-backup.timer\`")
            warning_lines+=("**Logs:** \`journalctl -u configs-backup.service -n 50\`")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_ERROR
        elif [[ "${CONFIGS_STATUS:-}" == "Stale" ]]; then
            warning_lines+=("**Warning:** Configs backup is stale (older than ${CONFIGS_BACKUP_STALE_HOURS} hours).")
            warning_lines+=("**Action:** Verify backup schedule and check for failures.")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_WARNING
        fi
        has_warnings=1
    fi

    # Check Restore Test backup freshness and result
    if ((restore_test_check_result != 0)) || \
       [[ -z "${RESTORE_TEST_RUN_TIME:-}" ]] || \
       [[ "${RESTORE_TEST_RESULT:-}" == "Failed" ]] || \
       [[ "${RESTORE_TEST_STATUS:-}" == "Stale" ]]; then

        if ((restore_test_check_result != 0)) || [[ -z "${RESTORE_TEST_RUN_TIME:-}" ]]; then
            warning_lines+=("**Warning:** Restore-test status check failed or no restore-test data available.")
            warning_lines+=("**Action:** Check systemd timer: \`systemctl status restore-test.timer\`")
            warning_lines+=("**Logs:** \`journalctl -u restore-test.service -n 50\`")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_ERROR
        elif [[ "${RESTORE_TEST_RESULT:-}" == "Failed" ]]; then
            warning_lines+=("**Warning:** Last restore test failed (${RESTORE_TEST_PASSED_CHECKS:-0}/${RESTORE_TEST_TOTAL_CHECKS:-0} checks passed).")
            warning_lines+=("**Action:** Review latest restore-test logs and rerun manually.")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_ERROR
        elif [[ "${RESTORE_TEST_STATUS:-}" == "Stale" ]]; then
            warning_lines+=("**Warning:** Restore test is stale (older than ${RESTORE_TEST_STALE_DAYS} days).")
            warning_lines+=("**Action:** Trigger restore test manually: \`${BACKUPS_DIR}/orchestration/restore-test.sh\`")
            [[ $exit_code -eq $EXIT_SUCCESS ]] && exit_code=$EXIT_WARNING
        fi
        has_warnings=1
    fi
    
    # Build final message from array - Issue 16
    local status_msg
    printf -v status_msg '%s\n' "${status_lines[@]}"
    
    # Add warnings if any
    if ((has_warnings > 0)); then
        status_msg+="\\n"
        local warning_msg
        printf -v warning_msg '%s\n' "${warning_lines[@]}"
        status_msg+="${warning_msg}"
    fi
    
    # Check if we should send Discord notification
    # Send if: (1) there's an error/warning, OR (2) it's Saturday (6) or Sunday (7)
    local day_of_week=$(date +%u)
    local should_send_discord=0
    
    if ((exit_code == EXIT_ERROR)) || ((exit_code == EXIT_WARNING)); then
        # Always send on errors or warnings
        should_send_discord=1
        echo "Sending Discord notification: Status contains warnings or errors"
    elif ((day_of_week == 6)) || ((day_of_week == 7)); then
        # Send on weekends even if healthy
        should_send_discord=1
        echo "Sending Discord notification: Weekend heartbeat"
    else
        echo "Skipping Discord notification: Weekday with healthy status"
    fi
    
    # Send notification based on exit code - Issue 6,17
    if ((should_send_discord == 1)); then
        if ((exit_code == EXIT_ERROR)); then
            status_msg+="\\n**CRITICAL:** Immediate attention required."
            if ! send_discord "Daily Heartbeat: Critical Errors" "$status_msg" 15548997 "🚨"; then
                echo "ERROR: Failed to send Discord notification" >&2
                return $EXIT_ERROR
            fi
        elif ((exit_code == EXIT_WARNING)); then
            if ! send_discord "Daily Heartbeat: Issues Detected" "$status_msg" 16776960 "⚠️"; then
                echo "ERROR: Failed to send Discord notification" >&2
                return $EXIT_ERROR
            fi
        else
            status_msg+="\\nAll systems nominal."
            if ! send_discord "Backup System Healthy" "$status_msg" 5763719 "✅"; then
                echo "ERROR: Failed to send Discord notification" >&2
                return $EXIT_ERROR
            fi
        fi
    else
        # Log what would have been sent (even when skipped)
        local log_title log_color log_emoji log_msg
        log_msg="${status_msg}"
        if ((exit_code == EXIT_ERROR)); then
            log_title="Daily Heartbeat: Critical Errors"
            log_color=15548997
            log_emoji="🚨"
            log_msg+="\\n**CRITICAL:** Immediate attention required."
        elif ((exit_code == EXIT_WARNING)); then
            log_title="Daily Heartbeat: Issues Detected"
            log_color=16776960
            log_emoji="⚠️"
        else
            log_title="Backup System Healthy"
            log_color=5763719
            log_emoji="✅"
            log_msg+="\\nAll systems nominal."
        fi
        
        # Log notification details that would have been sent
        echo "--- Would Have Sent Discord Notification ---"
        echo "Title: ${log_emoji} ${log_title}"
        echo "Color: ${log_color}"
        echo "Description:"
        printf '%b\n' "$log_msg"
        echo "-------------------------------------------"
    fi

    return $exit_code
}

# Parse arguments
case "${1:-status}" in
    status)
        main
        ;;
    heartbeat)
        heartbeat
        ;;
    *)
        echo "Usage: $0 {status|heartbeat}"
        echo "  status    - Display detailed backup status"
        echo "  heartbeat - Send daily health check to Discord"
        exit 1
        ;;
esac
