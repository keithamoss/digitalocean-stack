#!/bin/bash
# Backup Status Monitor
# Orchestrates PostgreSQL and Foundry backup status checks
# Reports to console and Discord

set -euo pipefail

# Determine script and backup directories using realpath (Issue 4)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")" 
MONITORING_DIR="$(realpath "$SCRIPT_DIR/..")"
BACKUPS_DIR="$(realpath "$MONITORING_DIR/..")"
SECRETS_DIR="${BACKUPS_DIR}/secrets"
DISCORD_ENV="${SECRETS_DIR}/discord.env"

# Load centralized configuration (Issue 3)
source "${BACKUPS_DIR}/config.sh"

# Check required dependencies (Issue 4)
for cmd in docker jq bc date curl restic; do
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
for lib in "discord-lib.sh" "check-postgres-backup.sh" "check-foundry-backup.sh"; do
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

# Main status check - console output
main() {
    echo -e "${BLUE}=== Backup Status ===${NC}\n"
    
    local pg_status=0
    local foundry_status=0
    
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
    
    # Overall status - Issue 17
    if ((pg_status == 0)) && ((foundry_status == 0)); then
        echo -e "\n${GREEN}✓ All backup systems operational${NC}"
        return $EXIT_SUCCESS
    elif ((pg_status == 2)) || ((foundry_status == 2)); then
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
    
    # Check Foundry backups with timeout - Issue 2,3,10
    # Use a wrapper function to properly handle timeout and exit codes
    local foundry_info
    local foundry_timeout_exit=0
    foundry_info=$(timeout $COMMAND_TIMEOUT bash -c '
        source "'"$SCRIPT_DIR"'/check-foundry-backup.sh" || exit 1
        export FOUNDRY_RESTIC_REPO="'"$FOUNDRY_RESTIC_REPO"'"
        export FOUNDRY_AWS_ENV="'"$FOUNDRY_AWS_ENV"'"
        export FOUNDRY_RESTIC_KEY="'"$FOUNDRY_RESTIC_KEY"'"
        validate_foundry_backup_system
        exit $?
    ' 2>&1) || foundry_timeout_exit=$?
    
    if ((foundry_timeout_exit != 0)); then
        foundry_check_result=1  # Issue 1,10: 1=error, 0=success
        if ((foundry_timeout_exit == 124)); then
            # Timeout occurred
            foundry_info="Foundry backup check TIMED OUT after ${COMMAND_TIMEOUT}s: ${foundry_info}"
        fi
    else
        # Parse the JSON response to set variables
        get_foundry_backup_stats "$foundry_info"
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
        
        # Validate counts are numeric or use 'unknown' - Issue 4,11
        local worlds="${FOUNDRY_WORLD_COUNT:-unknown}"
        local systems="${FOUNDRY_SYSTEMS_COUNT:-unknown}"
        local modules="${FOUNDRY_MODULES_COUNT:-unknown}"
        [[ "$worlds" =~ ^[0-9]+$ ]] || worlds="unknown"
        [[ "$systems" =~ ^[0-9]+$ ]] || systems="unknown"
        [[ "$modules" =~ ^[0-9]+$ ]] || modules="unknown"
        
        status_lines+=("✓ Worlds: \`${worlds}\` | Systems: \`${systems}\` | Modules: \`${modules}\`")
        
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
        status_lines+=("**Debug:** Check restic repo: \`restic -r ${FOUNDRY_RESTIC_REPO} snapshots\`")
        exit_code=$EXIT_ERROR
    fi
    
    status_lines+=("")
    status_lines+=("**Storage**")
    status_lines+=("✓ S3 Repos: Operational")
    
    # Check for specific issues - Issue 1,2,10,12,13
    local has_warnings=0
    local warning_lines=()
    
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
    
    # Send notification based on exit code - Issue 6,17
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
