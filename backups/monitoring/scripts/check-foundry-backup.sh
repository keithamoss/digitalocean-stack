#!/bin/bash
# Foundry VTT Backup Status Check (restic)
# Provides functions to check and report Foundry backup status
#
# This script is sourced by backup-status.sh, not run directly

# Note: Configuration now comes from centralized config.sh (Issue 3)
# FOUNDRY_RESTIC_REPO, FOUNDRY_AWS_ENV, FOUNDRY_RESTIC_KEY are set by caller

# validate_foundry_backup_system
#
# Validates Foundry backup system and returns JSON info
# Checks restic repository accessibility and retrieves latest snapshot
#
# Globals Used:
#   FOUNDRY_RESTIC_REPO - S3 repository URL
#   FOUNDRY_AWS_ENV - Path to AWS credentials file
#   FOUNDRY_RESTIC_KEY - Path to restic password file
#   FOUNDRY_EXPECTED_MAX_AGE_DAYS - Maximum expected age for oldest backup
#
# Returns:
#   0 on success, 1 on failure
#   JSON string with backup metadata on stdout
#   Error messages on stderr
validate_foundry_backup_system() {
    # Load AWS credentials
    if [[ ! -f "$FOUNDRY_AWS_ENV" ]]; then
        echo "ERROR: AWS credentials not found at $FOUNDRY_AWS_ENV" >&2
        return 1
    fi
    source "$FOUNDRY_AWS_ENV"
    
    # Load restic password
    if [[ ! -f "$FOUNDRY_RESTIC_KEY" ]]; then
        echo "ERROR: Restic key not found at $FOUNDRY_RESTIC_KEY" >&2
        return 1
    fi
    export RESTIC_PASSWORD=$(cat "$FOUNDRY_RESTIC_KEY")
    
    # Get snapshots with JSON validation (Issue 15)
    # Note: When run as root, shell initialization may print messages to stdout
    # We need to extract only the JSON array from the output
    # Use --no-cache for faster status checks (we're only reading metadata, not restoring)
    local snapshots
    local restic_output
    local restic_stderr
    
    # Capture stdout and stderr separately
    restic_stderr=$(mktemp)
    if ! restic_output=$(restic --no-cache -r "$FOUNDRY_RESTIC_REPO" snapshots --json --latest 1 2>"$restic_stderr"); then
        local error_msg=$(cat "$restic_stderr")
        rm -f "$restic_stderr"
        echo "ERROR: Failed to query restic repository: $error_msg" >&2
        return 1
    fi
    rm -f "$restic_stderr"
    
    # Extract only the JSON array (lines starting with '[' or '{')
    # This filters out shell initialization messages like "Wi-Fi is currently blocked"
    snapshots=$(echo "$restic_output" | grep -E '^\[|^\{' | head -1)
    
    if [[ -z "$snapshots" ]]; then
        echo "ERROR: No JSON output found from restic. Raw output: ${restic_output:0:200}" >&2
        return 1
    fi
    
    # Validate JSON is parseable (Issue 15)
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
        echo "ERROR: No Foundry backups found" >&2
        return 1
    fi
    
    # Extract latest snapshot info (sort by time descending, take first)
    # When paths change, --latest 1 returns multiple snapshots (one per path group)
    # so we explicitly sort by time to get the absolute latest
    local snapshot_id=$(echo "$snapshots" | jq -r 'sort_by(.time) | reverse | .[0].short_id')
    
    # Issue 4: Validate date parsing - get ISO8601 time and validate before conversion
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
    
    # Validate timestamp is reasonable (not in future, not too old)
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
    
    # Get oldest snapshot for pruning health check
    local oldest_snapshot_time="$snapshot_time"
    local pruning_status="Healthy"
    local pruning_message=""
    
    local all_snapshots
    local all_snapshots_raw
    if all_snapshots_raw=$(restic --no-cache -r "$FOUNDRY_RESTIC_REPO" snapshots --json --tag foundry 2>/dev/null); then
        # Extract only the JSON array, filtering out shell initialization messages
        all_snapshots=$(echo "$all_snapshots_raw" | grep -E '^\[|^\{' | head -1)
        
        if [[ -n "$all_snapshots" ]] && echo "$all_snapshots" | jq empty 2>/dev/null; then
            # Get oldest snapshot time - restic returns ISO8601 format
            local oldest_time_str=$(echo "$all_snapshots" | jq -r 'min_by(.time) | .time')
            if [[ -n "$oldest_time_str" ]] && [[ "$oldest_time_str" != "null" ]]; then
                # Issue 4: Validate date parsing before use
                if oldest_snapshot_time=$(date -d "$oldest_time_str" +%s 2>/dev/null); then
                    # Validate timestamp is reasonable
                    if ((oldest_snapshot_time > now + 3600)) || ((oldest_snapshot_time < now - 63072000)); then
                        echo "WARNING: Oldest snapshot time outside reasonable range: $oldest_time_str" >&2
                        oldest_snapshot_time="$snapshot_time"  # Fall back to latest snapshot time
                    fi
                else
                    echo "WARNING: Failed to parse oldest snapshot time: $oldest_time_str" >&2
                    oldest_snapshot_time="$snapshot_time"  # Fall back to latest snapshot time
                fi
            fi
        fi
        
        # Check oldest backup age for pruning health (Issue 17)
        # RETENTION POLICY: This check uses constants from backups/config.sh
        #   FOUNDRY_RETENTION_DAILY, FOUNDRY_RETENTION_MONTHLY, FOUNDRY_EXPECTED_MAX_AGE_DAYS
        #   If you change the retention policy, update config.sh
        local now=$(date +%s)
        local oldest_age_days=$(( (now - oldest_snapshot_time) / 86400 ))
        if (( oldest_age_days > FOUNDRY_EXPECTED_MAX_AGE_DAYS )); then
            pruning_status="Warning"
            pruning_message="Oldest backup is ${oldest_age_days} days old (expected < ${expected_max_age_days} days)"
        fi
    else
        pruning_status="Unknown"
    fi
    

    
    # Calculate age
    local age_seconds=$((now - snapshot_time))
    local age_hours=$((age_seconds / 3600))
    
    # Determine status
    local status="Healthy"
    if ((age_hours > 36)); then
        status="Stale"
    fi
    
    # Output as JSON to stdout
    jq -n \
        --arg snapshot_id "$snapshot_id" \
        --arg snapshot_time "$snapshot_time" \
        --arg snapshot_files "$snapshot_files" \
        --arg snapshot_size "$snapshot_size" \
        --arg oldest_snapshot_time "$oldest_snapshot_time" \
        --arg pruning_status "$pruning_status" \
        --arg pruning_message "$pruning_message" \
        --arg age_hours "$age_hours" \
        --arg status "$status" \
        '{
            snapshot_id: $snapshot_id,
            snapshot_time: $snapshot_time,
            snapshot_files: $snapshot_files,
            snapshot_size: $snapshot_size,
            oldest_snapshot_time: $oldest_snapshot_time,
            pruning_status: $pruning_status,
            pruning_message: $pruning_message,
            age_hours: $age_hours,
            status: $status
        }'
    
    return 0
}

# get_foundry_backup_stats
#
# Parses Foundry backup info JSON and sets global variables
# Similar to get_postgres_backup_stats for consistency
#
# Arguments:
#   $1 - JSON string from validate_foundry_backup_system
#
# Globals Set:
#   FOUNDRY_SNAPSHOT_ID - Snapshot ID
#   FOUNDRY_SNAPSHOT_TIME - Snapshot timestamp
#   FOUNDRY_SNAPSHOT_FILES - Number of files in snapshot
#   FOUNDRY_SNAPSHOT_SIZE - Size of snapshot in bytes
#   FOUNDRY_OLDEST_SNAPSHOT_TIME - Oldest snapshot timestamp
#   FOUNDRY_PRUNING_STATUS - Pruning health status
#   FOUNDRY_PRUNING_MESSAGE - Pruning status details
#   FOUNDRY_AGE_HOURS - Age of backup in hours
#   FOUNDRY_STATUS - Overall status (Healthy/Stale)
#   FOUNDRY_STATUS_EMOJI - Status emoji
get_foundry_backup_stats() {
    local foundry_info="$1"
    
    # Parse JSON and set global variables for compatibility with existing code
    FOUNDRY_SNAPSHOT_ID=$(echo "$foundry_info" | jq -r '.snapshot_id')
    FOUNDRY_SNAPSHOT_TIME=$(echo "$foundry_info" | jq -r '.snapshot_time')
    FOUNDRY_SNAPSHOT_FILES=$(echo "$foundry_info" | jq -r '.snapshot_files')
    FOUNDRY_SNAPSHOT_SIZE=$(echo "$foundry_info" | jq -r '.snapshot_size')
    FOUNDRY_OLDEST_SNAPSHOT_TIME=$(echo "$foundry_info" | jq -r '.oldest_snapshot_time')
    FOUNDRY_PRUNING_STATUS=$(echo "$foundry_info" | jq -r '.pruning_status')
    FOUNDRY_PRUNING_MESSAGE=$(echo "$foundry_info" | jq -r '.pruning_message')
    FOUNDRY_AGE_HOURS=$(echo "$foundry_info" | jq -r '.age_hours')
    FOUNDRY_STATUS=$(echo "$foundry_info" | jq -r '.status')
    
    # Set emoji based on status
    if [[ "$FOUNDRY_STATUS" == "Healthy" ]]; then
        FOUNDRY_STATUS_EMOJI="✓"
    else
        FOUNDRY_STATUS_EMOJI="⚠"
    fi
}

# display_foundry_status
#
# Displays Foundry backup status to console with color formatting
#
# Globals Used:
#   Color variables (RED, GREEN, YELLOW, BLUE, NC)
#   Various FOUNDRY_* variables set by get_foundry_backup_stats
#
# Returns:
#   0 if all checks pass, 1 if warnings detected
display_foundry_status() {
    echo -e "\n${BLUE}--- Foundry VTT (restic) ---${NC}"
    
    local foundry_info
    if ! foundry_info=$(validate_foundry_backup_system 2>&1); then
        echo -e "${RED}✗ Foundry backup validation failed${NC}"
        echo -e "${RED}${foundry_info}${NC}"
        return 1
    fi
    
    # Parse the JSON response
    get_foundry_backup_stats "$foundry_info"
    
    if [[ "$FOUNDRY_STATUS" == "Healthy" ]]; then
        echo -e "${GREEN}✓ Status:${NC}             $FOUNDRY_STATUS"
    else
        echo -e "${YELLOW}⚠ Status:${NC}             $FOUNDRY_STATUS (${FOUNDRY_AGE_HOURS}h since last backup)"
    fi
    echo -e "${GREEN}✓ Last backup:${NC}        $(date -d "@$FOUNDRY_SNAPSHOT_TIME" '+%Y-%m-%d %H:%M:%S')"
    echo -e "${GREEN}✓ Size:${NC}               $(format_bytes $FOUNDRY_SNAPSHOT_SIZE)"
    echo -e "${GREEN}✓ Files:${NC}              $FOUNDRY_SNAPSHOT_FILES"
    
    local oldest_age_days=$(( ($(date +%s) - FOUNDRY_OLDEST_SNAPSHOT_TIME) / 86400 ))
    if [[ "${FOUNDRY_PRUNING_STATUS}" == "Warning" ]]; then
        echo -e "${YELLOW}⚠ Oldest backup:${NC}      $(date -d "@$FOUNDRY_OLDEST_SNAPSHOT_TIME" '+%Y-%m-%d %H:%M:%S') (${oldest_age_days} days - pruning may not be working)"
    else
        echo -e "${GREEN}✓ Oldest backup:${NC}      $(date -d "@$FOUNDRY_OLDEST_SNAPSHOT_TIME" '+%Y-%m-%d %H:%M:%S') (${oldest_age_days} days)"
    fi
    
    if [[ "$FOUNDRY_STATUS" != "Healthy" ]] || [[ "${FOUNDRY_PRUNING_STATUS}" == "Warning" ]]; then
        return 1
    fi
    return 0
}
