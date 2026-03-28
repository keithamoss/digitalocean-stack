#!/bin/bash
# Logs Backup Status Check (s3 sync)
# Provides functions to check and report logs backup status
#
# This script is sourced by backup-status.sh, not run directly
#
# Note: Configuration now comes from centralized config.sh
# LOGS_S3_PATH, LOGS_AWS_ENV are set by caller

# validate_logs_backup_system
#
# Validates logs backup system and returns JSON info
# Reads .last-sync sentinel from S3 and queries S3 for file/size stats
#
# Globals Used:
#   LOGS_S3_PATH - S3 destination path (s3://bucket/prefix)
#   LOGS_AWS_ENV - Path to AWS credentials file
#   LOGS_BACKUP_STALE_HOURS - Hours before backup considered stale
#
# Returns:
#   0 on success, 1 on failure
#   JSON string with backup metadata on stdout
#   Error messages on stderr
validate_logs_backup_system() {
    # Check aws CLI is available
    if ! command -v aws >/dev/null 2>&1; then
        echo "ERROR: aws CLI is not installed" >&2
        return 1
    fi

    # Load AWS credentials
    if [[ ! -f "$LOGS_AWS_ENV" ]]; then
        echo "ERROR: AWS credentials not found at $LOGS_AWS_ENV" >&2
        return 1
    fi
    source "$LOGS_AWS_ENV"

    # Download .last-sync sentinel file from S3
    local tmp_sentinel
    tmp_sentinel=$(mktemp)
    if ! aws s3 cp "${LOGS_S3_PATH}/.last-sync" "$tmp_sentinel" >/dev/null 2>&1; then
        rm -f "$tmp_sentinel"
        echo "ERROR: Could not retrieve .last-sync from ${LOGS_S3_PATH}/.last-sync — has the first sync run yet?" >&2
        return 1
    fi

    # Parse sentinel: format is "<ISO8601-timestamp> <hostname>"
    local sync_time_str
    sync_time_str=$(cut -d' ' -f1 "$tmp_sentinel")
    rm -f "$tmp_sentinel"

    if [[ -z "$sync_time_str" ]]; then
        echo "ERROR: .last-sync sentinel is empty or malformed" >&2
        return 1
    fi

    # Convert ISO8601 timestamp to epoch for age calculation
    local sync_epoch
    if ! sync_epoch=$(date -d "$sync_time_str" +%s 2>/dev/null); then
        echo "ERROR: Failed to parse sync timestamp: $sync_time_str" >&2
        return 1
    fi

    # Validate timestamp is reasonable
    local now
    now=$(date +%s)
    if ((sync_epoch > now + 3600)); then
        echo "ERROR: Sync time is in the future: $sync_time_str" >&2
        return 1
    fi

    # Get S3 file count and total size via summarize
    local s3_ls_output
    local s3_files=0
    local s3_size=0
    if s3_ls_output=$(aws s3 ls --recursive --summarize "${LOGS_S3_PATH}/" 2>/dev/null); then
        s3_files=$(echo "$s3_ls_output" | awk '/Total Objects:/ { print $NF }')
        s3_size=$(echo "$s3_ls_output" | awk '/Total Size:/ { print $NF }')
        s3_files=${s3_files:-0}
        s3_size=${s3_size:-0}
    fi

    # Calculate age and determine staleness
    local age_seconds=$((now - sync_epoch))
    local age_hours=$((age_seconds / 3600))

    local status="Healthy"
    if ((age_hours > LOGS_BACKUP_STALE_HOURS)); then
        status="Stale"
    fi

    # Output as JSON
    jq -n \
        --arg sync_time "$sync_time_str" \
        --arg s3_files "$s3_files" \
        --arg s3_size "$s3_size" \
        --arg age_hours "$age_hours" \
        --arg status "$status" \
        '{
            sync_time: $sync_time,
            s3_files: $s3_files,
            s3_size: $s3_size,
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
#   LOGS_SYNC_TIME - Last sync ISO8601 timestamp
#   LOGS_S3_FILES - Total files in S3
#   LOGS_S3_SIZE - Total size of S3 files in bytes
#   LOGS_AGE_HOURS - Age of most recent sync in hours
#   LOGS_STATUS - Overall status (Healthy/Stale)
#   LOGS_STATUS_EMOJI - Status emoji
get_logs_backup_stats() {
    local logs_info="$1"

    LOGS_SYNC_TIME=$(echo "$logs_info" | jq -r '.sync_time')
    LOGS_S3_FILES=$(echo "$logs_info" | jq -r '.s3_files')
    LOGS_S3_SIZE=$(echo "$logs_info" | jq -r '.s3_size')
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
    echo -e "\n${BLUE}--- Logs (s3 sync) ---${NC}"

    local logs_info
    if ! logs_info=$(validate_logs_backup_system 2>&1); then
        echo -e "${RED}✗ Logs backup validation failed${NC}"
        echo -e "${RED}${logs_info}${NC}"
        return 1
    fi

    get_logs_backup_stats "$logs_info"

    if [[ "$LOGS_STATUS" == "Healthy" ]]; then
        echo -e "${GREEN}✓ Status:${NC}          $LOGS_STATUS"
    else
        echo -e "${YELLOW}⚠ Status:${NC}          $LOGS_STATUS (${LOGS_AGE_HOURS}h since last sync)"
    fi
    echo -e "${GREEN}✓ Last sync:${NC}       $LOGS_SYNC_TIME"
    echo -e "${GREEN}✓ S3 files:${NC}        $LOGS_S3_FILES"
    echo -e "${GREEN}✓ S3 size:${NC}         $(format_bytes $LOGS_S3_SIZE)"

    if [[ "$LOGS_STATUS" != "Healthy" ]]; then
        return 1
    fi
    return 0
}
