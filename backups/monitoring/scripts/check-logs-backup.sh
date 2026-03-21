#!/bin/bash
# Logs Backup Status Check (restic)
# Provides functions to check and report logs backup status
#
# This script is sourced by backup-status.sh, not run directly
#
# Note: Configuration now comes from centralized config.sh
# LOGS_RESTIC_REPO, LOGS_AWS_ENV, LOGS_RESTIC_KEY are set by caller
# Retention policy: Keep all snapshots forever (no pruning)

# validate_logs_backup_system
#
# Validates logs backup system and returns JSON info
# Checks restic repository accessibility and retrieves latest snapshot
#
# Globals Used:
#   LOGS_RESTIC_REPO - S3 repository URL
#   LOGS_AWS_ENV - Path to AWS credentials file
#   LOGS_RESTIC_KEY - Path to restic password file
#   LOGS_BACKUP_STALE_HOURS - Hours before backup considered stale
#
# Returns:
#   0 on success, 1 on failure
#   JSON string with backup metadata on stdout
#   Error messages on stderr
validate_logs_backup_system() {
    # Load AWS credentials
    if [[ ! -f "$LOGS_AWS_ENV" ]]; then
        echo "ERROR: AWS credentials not found at $LOGS_AWS_ENV" >&2
        return 1
    fi
    source "$LOGS_AWS_ENV"

    # Load restic password
    if [[ ! -f "$LOGS_RESTIC_KEY" ]]; then
        echo "ERROR: Restic key not found at $LOGS_RESTIC_KEY" >&2
        return 1
    fi
    export RESTIC_PASSWORD=$(cat "$LOGS_RESTIC_KEY")

    # Get latest snapshot with JSON output
    # --no-cache for faster status checks (only reading metadata)
    local snapshots
    local restic_output
    local restic_stderr

    restic_stderr=$(mktemp)
    if ! restic_output=$(restic --no-cache -r "$LOGS_RESTIC_REPO" snapshots --json --latest 1 2>"$restic_stderr"); then
        local error_msg=$(cat "$restic_stderr")
        rm -f "$restic_stderr"
        echo "ERROR: Failed to query restic repository: $error_msg" >&2
        return 1
    fi
    rm -f "$restic_stderr"

    # Extract only the JSON array (filter out any shell init messages)
    snapshots=$(echo "$restic_output" | grep -E '^\[|^\{' | head -1)

    if [[ -z "$snapshots" ]]; then
        echo "ERROR: No JSON output found from restic. Raw output: ${restic_output:0:200}" >&2
        return 1
    fi

    # Validate JSON is parseable
    if ! echo "$snapshots" | jq empty 2>/dev/null; then
        echo "ERROR: Restic output is not valid JSON. Output: ${snapshots:0:200}" >&2
        return 1
    fi

    # Check if we have any snapshots
    local snapshot_count
    snapshot_count=$(echo "$snapshots" | jq '. | length' 2>/dev/null) || {
        echo "ERROR: Failed to parse snapshot count from JSON" >&2
        return 1
    }
    if [[ "$snapshot_count" == "0" ]]; then
        echo "ERROR: No logs backups found" >&2
        return 1
    fi

    # Extract latest snapshot (sort by time, take most recent)
    local snapshot_id=$(echo "$snapshots" | jq -r 'sort_by(.time) | reverse | .[0].short_id')

    local snapshot_time_str=$(echo "$snapshots" | jq -r 'sort_by(.time) | reverse | .[0].time')
    if [[ -z "$snapshot_time_str" ]] || [[ "$snapshot_time_str" == "null" ]]; then
        echo "ERROR: Failed to extract snapshot time from JSON" >&2
        return 1
    fi

    # Convert to epoch with validation
    local snapshot_time
    if ! snapshot_time=$(date -d "$snapshot_time_str" +%s 2>/dev/null); then
        echo "ERROR: Failed to parse snapshot time: $snapshot_time_str" >&2
        return 1
    fi

    # Validate timestamp is reasonable
    local now=$(date +%s)
    if ((snapshot_time > now + 3600)); then
        echo "ERROR: Snapshot time is in the future: $snapshot_time_str" >&2
        return 1
    fi
    if ((snapshot_time < now - 63072000)); then  # 2 years
        echo "ERROR: Snapshot time is more than 2 years old: $snapshot_time_str" >&2
        return 1
    fi

    local snapshot_files=$(echo "$snapshots" | jq -r 'sort_by(.time) | reverse | .[0].summary.total_files_processed // 0')
    local snapshot_size=$(echo "$snapshots" | jq -r 'sort_by(.time) | reverse | .[0].summary.total_bytes_processed // 0')

    # Get total snapshot count (for informational purposes - no pruning needed)
    local total_snapshot_count=0
    local all_snapshots_raw
    if all_snapshots_raw=$(restic --no-cache -r "$LOGS_RESTIC_REPO" snapshots --json --tag logs 2>/dev/null); then
        local all_snapshots
        all_snapshots=$(echo "$all_snapshots_raw" | grep -E '^\[|^\{' | head -1)
        if [[ -n "$all_snapshots" ]] && echo "$all_snapshots" | jq empty 2>/dev/null; then
            total_snapshot_count=$(echo "$all_snapshots" | jq '. | length' 2>/dev/null || echo 0)
        fi
    fi

    # Get total unique file count across entire repository
    # This grows predictably each day as new rotated log files are added
    local total_file_count=0
    local repo_stats_raw
    if repo_stats_raw=$(restic --no-cache -r "$LOGS_RESTIC_REPO" stats --json 2>/dev/null); then
        local repo_stats
        repo_stats=$(echo "$repo_stats_raw" | grep -E '^\{' | head -1)
        if [[ -n "$repo_stats" ]] && echo "$repo_stats" | jq empty 2>/dev/null; then
            total_file_count=$(echo "$repo_stats" | jq -r '.total_file_count // 0')
        fi
    fi

    # Calculate age and determine staleness
    local age_seconds=$((now - snapshot_time))
    local age_hours=$((age_seconds / 3600))

    local status="Healthy"
    if ((age_hours > LOGS_BACKUP_STALE_HOURS)); then
        status="Stale"
    fi

    # Output as JSON
    jq -n \
        --arg snapshot_id "$snapshot_id" \
        --arg snapshot_time "$snapshot_time" \
        --arg snapshot_files "$snapshot_files" \
        --arg snapshot_size "$snapshot_size" \
        --arg total_snapshot_count "$total_snapshot_count" \
        --arg total_file_count "$total_file_count" \
        --arg age_hours "$age_hours" \
        --arg status "$status" \
        '{
            snapshot_id: $snapshot_id,
            snapshot_time: $snapshot_time,
            snapshot_files: $snapshot_files,
            snapshot_size: $snapshot_size,
            total_snapshot_count: $total_snapshot_count,
            total_file_count: $total_file_count,
            age_hours: $age_hours,
            status: $status
        }'

    return 0
}

# get_logs_backup_stats
#
# Parses logs backup info JSON and sets global variables
#
# Arguments:
#   $1 - JSON string from validate_logs_backup_system
#
# Globals Set:
#   LOGS_SNAPSHOT_ID - Snapshot ID
#   LOGS_SNAPSHOT_TIME - Snapshot timestamp (epoch)
#   LOGS_SNAPSHOT_FILES - Number of files in snapshot
#   LOGS_SNAPSHOT_SIZE - Size of snapshot in bytes
#   LOGS_TOTAL_SNAPSHOTS - Total number of snapshots
#   LOGS_TOTAL_FILES - Total unique files stored across all snapshots (grows daily)
#   LOGS_AGE_HOURS - Age of most recent backup in hours
#   LOGS_STATUS - Overall status (Healthy/Stale)
#   LOGS_STATUS_EMOJI - Status emoji
get_logs_backup_stats() {
    local logs_info="$1"

    LOGS_SNAPSHOT_ID=$(echo "$logs_info" | jq -r '.snapshot_id')
    LOGS_SNAPSHOT_TIME=$(echo "$logs_info" | jq -r '.snapshot_time')
    LOGS_SNAPSHOT_FILES=$(echo "$logs_info" | jq -r '.snapshot_files')
    LOGS_SNAPSHOT_SIZE=$(echo "$logs_info" | jq -r '.snapshot_size')
    LOGS_TOTAL_SNAPSHOTS=$(echo "$logs_info" | jq -r '.total_snapshot_count')
    LOGS_TOTAL_FILES=$(echo "$logs_info" | jq -r '.total_file_count')
    LOGS_AGE_HOURS=$(echo "$logs_info" | jq -r '.age_hours')
    LOGS_STATUS=$(echo "$logs_info" | jq -r '.status')

    if [[ "$LOGS_STATUS" == "Healthy" ]]; then
        LOGS_STATUS_EMOJI="✓"
    else
        LOGS_STATUS_EMOJI="⚠"
    fi
}

# display_logs_status
#
# Displays logs backup status to console with color formatting
#
# Globals Used:
#   Color variables (RED, GREEN, YELLOW, BLUE, NC)
#   Various LOGS_* variables set by get_logs_backup_stats
#
# Returns:
#   0 if all checks pass, 1 if warnings detected
display_logs_status() {
    echo -e "\n${BLUE}--- Logs (restic) ---${NC}"

    local logs_info
    if ! logs_info=$(validate_logs_backup_system 2>&1); then
        echo -e "${RED}✗ Logs backup validation failed${NC}"
        echo -e "${RED}${logs_info}${NC}"
        return 1
    fi

    get_logs_backup_stats "$logs_info"

    if [[ "$LOGS_STATUS" == "Healthy" ]]; then
        echo -e "${GREEN}✓ Status:${NC}             $LOGS_STATUS"
    else
        echo -e "${YELLOW}⚠ Status:${NC}             $LOGS_STATUS (${LOGS_AGE_HOURS}h since last backup)"
    fi
    echo -e "${GREEN}✓ Last backup:${NC}        $(date -d "@$LOGS_SNAPSHOT_TIME" '+%Y-%m-%d %H:%M:%S')"
    echo -e "${GREEN}✓ Size:${NC}               $(format_bytes $LOGS_SNAPSHOT_SIZE)"
    echo -e "${GREEN}✓ Total snapshots:${NC}    $LOGS_TOTAL_SNAPSHOTS (retained forever)"
    echo -e "${GREEN}✓ Total files stored:${NC} $LOGS_TOTAL_FILES (unique, grows ~daily)"

    if [[ "$LOGS_STATUS" != "Healthy" ]]; then
        return 1
    fi
    return 0
}
