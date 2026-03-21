#!/bin/bash
# Configs Backup Status Check (restic)
# Provides functions to check and report configs backup status
#
# This script is sourced by backup-status.sh, not run directly
#
# Note: Configuration now comes from centralized config.sh
# CONFIGS_RESTIC_REPO, CONFIGS_AWS_ENV, CONFIGS_RESTIC_KEY are set by caller
# Retention policy: 30 daily + monthly forever (CONFIGS_RETENTION_DAILY/MONTHLY)

# validate_configs_backup_system
#
# Validates configs backup system and returns JSON info
# Checks restic repository accessibility and retrieves latest snapshot
#
# Globals Used:
#   CONFIGS_RESTIC_REPO - S3 repository URL
#   CONFIGS_AWS_ENV - Path to AWS credentials file
#   CONFIGS_RESTIC_KEY - Path to restic password file
#   CONFIGS_BACKUP_STALE_HOURS - Hours before backup considered stale
#
# Returns:
#   0 on success, 1 on failure
#   JSON string with backup metadata on stdout
#   Error messages on stderr
validate_configs_backup_system() {
    # Load AWS credentials
    if [[ ! -f "$CONFIGS_AWS_ENV" ]]; then
        echo "ERROR: AWS credentials not found at $CONFIGS_AWS_ENV" >&2
        return 1
    fi
    source "$CONFIGS_AWS_ENV"

    # Load restic password
    if [[ ! -f "$CONFIGS_RESTIC_KEY" ]]; then
        echo "ERROR: Restic key not found at $CONFIGS_RESTIC_KEY" >&2
        return 1
    fi
    export RESTIC_PASSWORD=$(cat "$CONFIGS_RESTIC_KEY")

    # Get latest snapshot with JSON output
    # --no-cache for faster status checks (only reading metadata)
    local snapshots
    local restic_output
    local restic_stderr

    restic_stderr=$(mktemp)
    if ! restic_output=$(restic --no-cache -r "$CONFIGS_RESTIC_REPO" snapshots --json --latest 2 2>"$restic_stderr"); then
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
        echo "ERROR: No configs backups found" >&2
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

    # Compute file count delta vs previous snapshot (0 if only one snapshot exists)
    local prev_snapshot_files=0
    local file_delta=0
    local snapshot_count_for_delta
    snapshot_count_for_delta=$(echo "$snapshots" | jq '. | length' 2>/dev/null || echo 0)
    if [[ "$snapshot_count_for_delta" -ge 2 ]]; then
        prev_snapshot_files=$(echo "$snapshots" | jq -r 'sort_by(.time) | reverse | .[1].summary.total_files_processed // 0')
        file_delta=$((snapshot_files - prev_snapshot_files))
    fi

    # Get total snapshot count (for informational purposes)
    local total_snapshot_count=0
    local all_snapshots_raw
    if all_snapshots_raw=$(restic --no-cache -r "$CONFIGS_RESTIC_REPO" snapshots --json --tag configs 2>/dev/null); then
        local all_snapshots
        all_snapshots=$(echo "$all_snapshots_raw" | grep -E '^\[|^\{' | head -1)
        if [[ -n "$all_snapshots" ]] && echo "$all_snapshots" | jq empty 2>/dev/null; then
            total_snapshot_count=$(echo "$all_snapshots" | jq '. | length' 2>/dev/null || echo 0)
        fi
    fi

    # Calculate age and determine staleness
    local age_seconds=$((now - snapshot_time))
    local age_hours=$((age_seconds / 3600))

    local status="Healthy"
    if ((age_hours > CONFIGS_BACKUP_STALE_HOURS)); then
        status="Stale"
    fi

    # Output as JSON
    jq -n \
        --arg snapshot_id "$snapshot_id" \
        --arg snapshot_time "$snapshot_time" \
        --arg snapshot_files "$snapshot_files" \
        --arg snapshot_size "$snapshot_size" \
        --arg total_snapshot_count "$total_snapshot_count" \
        --arg age_hours "$age_hours" \
        --arg status "$status" \
        --arg prev_snapshot_files "$prev_snapshot_files" \
        --arg file_delta "$file_delta" \
        '{
            snapshot_id: $snapshot_id,
            snapshot_time: $snapshot_time,
            snapshot_files: $snapshot_files,
            snapshot_size: $snapshot_size,
            total_snapshot_count: $total_snapshot_count,
            age_hours: $age_hours,
            status: $status,
            prev_snapshot_files: $prev_snapshot_files,
            file_delta: $file_delta
        }'

    return 0
}

# get_configs_backup_stats
#
# Parses configs backup info JSON and sets global variables
#
# Arguments:
#   $1 - JSON string from validate_configs_backup_system
#
# Globals Set:
#   CONFIGS_SNAPSHOT_ID - Snapshot ID
#   CONFIGS_SNAPSHOT_TIME - Snapshot timestamp (epoch)
#   CONFIGS_SNAPSHOT_FILES - Number of files in snapshot
#   CONFIGS_SNAPSHOT_SIZE - Size of snapshot in bytes
#   CONFIGS_TOTAL_SNAPSHOTS - Total number of snapshots
#   CONFIGS_AGE_HOURS - Age of most recent backup in hours
#   CONFIGS_STATUS - Overall status (Healthy/Stale)
#   CONFIGS_STATUS_EMOJI - Status emoji
get_configs_backup_stats() {
    local configs_info="$1"

    CONFIGS_SNAPSHOT_ID=$(echo "$configs_info" | jq -r '.snapshot_id')
    CONFIGS_SNAPSHOT_TIME=$(echo "$configs_info" | jq -r '.snapshot_time')
    CONFIGS_SNAPSHOT_FILES=$(echo "$configs_info" | jq -r '.snapshot_files')
    CONFIGS_SNAPSHOT_SIZE=$(echo "$configs_info" | jq -r '.snapshot_size')
    CONFIGS_TOTAL_SNAPSHOTS=$(echo "$configs_info" | jq -r '.total_snapshot_count')
    CONFIGS_AGE_HOURS=$(echo "$configs_info" | jq -r '.age_hours')
    CONFIGS_STATUS=$(echo "$configs_info" | jq -r '.status')
    CONFIGS_FILE_DELTA=$(echo "$configs_info" | jq -r '.file_delta')
    CONFIGS_PREV_SNAPSHOT_FILES=$(echo "$configs_info" | jq -r '.prev_snapshot_files')

    if [[ "$CONFIGS_STATUS" == "Healthy" ]]; then
        CONFIGS_STATUS_EMOJI="✓"
    else
        CONFIGS_STATUS_EMOJI="⚠"
    fi
}

# display_configs_status
#
# Displays configs backup status to console with color formatting
#
# Globals Used:
#   Color variables (RED, GREEN, YELLOW, BLUE, NC)
#   Various CONFIGS_* variables set by get_configs_backup_stats
#
# Returns:
#   0 if all checks pass, 1 if warnings detected
display_configs_status() {
    echo -e "\n${BLUE}--- Configs (restic) ---${NC}"

    local configs_info
    if ! configs_info=$(validate_configs_backup_system 2>&1); then
        echo -e "${RED}✗ Configs backup validation failed${NC}"
        echo -e "${RED}${configs_info}${NC}"
        return 1
    fi

    get_configs_backup_stats "$configs_info"

    if [[ "$CONFIGS_STATUS" == "Healthy" ]]; then
        echo -e "${GREEN}✓ Status:${NC}             $CONFIGS_STATUS"
    else
        echo -e "${YELLOW}⚠ Status:${NC}             $CONFIGS_STATUS (${CONFIGS_AGE_HOURS}h since last backup)"
    fi
    echo -e "${GREEN}✓ Last backup:${NC}        $(date -d "@$CONFIGS_SNAPSHOT_TIME" '+%Y-%m-%d %H:%M:%S')"
    local configs_file_delta_str=""
    if [[ -n "${CONFIGS_FILE_DELTA:-}" ]] && [[ "${CONFIGS_FILE_DELTA}" =~ ^-?[0-9]+$ ]] && [[ "${CONFIGS_FILE_DELTA}" != "0" ]]; then
        if [[ "${CONFIGS_FILE_DELTA}" -gt 0 ]]; then
            configs_file_delta_str=" (+${CONFIGS_FILE_DELTA})"
        else
            configs_file_delta_str=" (${CONFIGS_FILE_DELTA})"
        fi
    fi
    echo -e "${GREEN}✓ Files:${NC}              ${CONFIGS_SNAPSHOT_FILES}${configs_file_delta_str}"
    echo -e "${GREEN}✓ Size:${NC}               $(format_bytes $CONFIGS_SNAPSHOT_SIZE)"
    echo -e "${GREEN}✓ Total snapshots:${NC}    $CONFIGS_TOTAL_SNAPSHOTS (30 daily + monthly forever)"

    if [[ "$CONFIGS_STATUS" != "Healthy" ]]; then
        return 1
    fi
    return 0
}
