#!/bin/bash
# PostgreSQL Backup Status Check (pgBackRest)
# Provides functions to check and report PostgreSQL backup status
#
# This script is sourced by backup-status.sh, not run directly

# Note: Configuration now comes from centralized config.sh (Issue 3)
# POSTGRES_DB_CONTAINER, POSTGRES_STANZA are set by config or environment

# get_postgres_backup_info
#
# Retrieves backup information from pgBackRest in JSON format
#
# Globals Used:
#   POSTGRES_DB_CONTAINER - Container name
#   POSTGRES_STANZA - Backup stanza name
#
# Returns:
#   0 on success, 1 on failure
#   JSON string with backup info on stdout
#   Error messages on stderr
get_postgres_backup_info() {
    local info
    info=$(docker exec "$POSTGRES_DB_CONTAINER" /usr/local/bin/pgbackrest-wrapper --stanza="$POSTGRES_STANZA" --output=json info 2>/dev/null) || {
        echo "ERROR: Failed to retrieve backup info" >&2
        return 1
    }
    
    # Validate JSON is parseable (Issue 15)
    if ! echo "$info" | jq empty 2>/dev/null; then
        echo "ERROR: Retrieved data is not valid JSON" >&2
        return 1
    fi
    
    # Issue 18: Validate expected JSON structure from pgBackRest
    # Check that we have an array with at least one stanza
    local stanza_count
    stanza_count=$(echo "$info" | jq '. | length' 2>/dev/null)
    if [[ -z "$stanza_count" ]] || [[ "$stanza_count" == "0" ]] || [[ "$stanza_count" == "null" ]]; then
        echo "ERROR: pgBackRest JSON has invalid structure (no stanza data)" >&2
        return 1
    fi
    
    # Verify required fields exist
    if ! echo "$info" | jq -e '.[0].backup' >/dev/null 2>&1; then
        echo "ERROR: pgBackRest JSON missing 'backup' field" >&2
        return 1
    fi
    
    if ! echo "$info" | jq -e '.[0].archive' >/dev/null 2>&1; then
        echo "ERROR: pgBackRest JSON missing 'archive' field" >&2
        return 1
    fi
    
    echo "$info"
}

# validate_postgres_backup_system
#
# Validates PostgreSQL backup system is operational
# Checks container is running and backups exist
#
# Globals Used:
#   POSTGRES_DB_CONTAINER - Container name
#   POSTGRES_STANZA - Backup stanza name
#
# Returns:
#   0 on success, 1 on failure
#   JSON string with backup info on stdout
#   Error messages on stderr
validate_postgres_backup_system() {
    # Check container
    if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_DB_CONTAINER}$"; then
        echo "ERROR: Container $POSTGRES_DB_CONTAINER is not running" >&2
        return 1
    fi
    
    # Get and validate backup info
    local info
    if ! info=$(get_postgres_backup_info); then
        echo "ERROR: Failed to retrieve backup info" >&2
        return 1
    fi
    
    # Validate backup count (Issue 15)
    local backup_count
    backup_count=$(echo "$info" | jq -r '.[0].backup | length' 2>/dev/null) || {
        echo "ERROR: Failed to parse backup count from JSON" >&2
        return 1
    }
    
    if [[ "$backup_count" == "0" ]] || [[ "$backup_count" == "null" ]] || [[ ! "$backup_count" =~ ^[0-9]+$ ]]; then
        echo "ERROR: No backups found or invalid backup count" >&2
        return 1
    fi
    
    echo "$info"
}

# get_wal_finalization_time
#
# Gets the timestamp when a WAL file was finalized/archived
# Uses pg_stat_archiver to get the actual archive completion time
#
# Arguments:
#   $1 - WAL filename
#
# Globals Used:
#   POSTGRES_DB_CONTAINER - Container name
#
# Returns:
#   0 on success, 1 on failure
#   Epoch timestamp on stdout if successful
get_wal_finalization_time() {
    local wal_file="$1"
    if [[ -z "$wal_file" ]]; then
        return 1
    fi
    
    # Get from pg_stat_archiver if this is the last archived WAL
    local pg_last_archived_wal
    local pg_last_archived_time
    local pg_result
    pg_result=$(docker exec "$POSTGRES_DB_CONTAINER" psql -U postgres -d postgres -t -A -c \
        "SELECT last_archived_wal, COALESCE(EXTRACT(EPOCH FROM last_archived_time)::bigint::text, 'NULL') FROM pg_stat_archiver WHERE last_archived_wal IS NOT NULL;" 2>/dev/null)
    
    if [[ -n "$pg_result" ]]; then
        IFS='|' read -r pg_last_archived_wal pg_last_archived_time <<< "$pg_result"
        
        # Issue 8: Validate that pg_last_archived_time is not NULL and is numeric
        if [[ "$pg_last_archived_wal" == "$wal_file" ]] && \
           [[ -n "$pg_last_archived_time" ]] && \
           [[ "$pg_last_archived_time" != "NULL" ]] && \
           [[ "$pg_last_archived_time" =~ ^[0-9]+$ ]]; then
            echo "$pg_last_archived_time"
            return 0
        fi
    fi
    
    return 1
}

# get_wal_archive_stats
#
# Retrieves WAL archive statistics from PostgreSQL
#
# Globals Set:
#   PG_WAL_ARCHIVED_COUNT - Total successful archives
#   PG_WAL_FAILED_COUNT - Total failed archives  
#   PG_WAL_LAST_FAILED_TIME - Timestamp of last failure
#   PG_WAL_STATS_RESET - Timestamp when stats were reset
#   PG_WAL_LAST_ARCHIVED_TIME - Timestamp of last successful archive
#   PG_WAL_FAILURE_RATE - Percentage of failures
#   PG_WAL_LAST_FAILED_AGE - Age of last failure in seconds
#
# Globals Used:
#   POSTGRES_DB_CONTAINER - Container name
get_wal_archive_stats() {
    local stats
    # Issue 8: Use COALESCE to handle NULL timestamps, convert to text 'NULL' for detection
    stats=$(docker exec "$POSTGRES_DB_CONTAINER" psql -U postgres -d postgres -t -A -c \
        "SELECT archived_count, failed_count, \
         COALESCE(EXTRACT(EPOCH FROM last_failed_time)::bigint::text, 'NULL'), \
         COALESCE(EXTRACT(EPOCH FROM stats_reset)::bigint::text, 'NULL'), \
         COALESCE(EXTRACT(EPOCH FROM last_archived_time)::bigint::text, 'NULL') \
         FROM pg_stat_archiver;" 2>/dev/null)
    if [[ -n "$stats" ]]; then
        PG_WAL_ARCHIVED_COUNT=$(echo "$stats" | cut -d'|' -f1)
        PG_WAL_FAILED_COUNT=$(echo "$stats" | cut -d'|' -f2)
        local wal_failed_time=$(echo "$stats" | cut -d'|' -f3)
        local wal_stats_reset=$(echo "$stats" | cut -d'|' -f4)
        local wal_last_archived=$(echo "$stats" | cut -d'|' -f5)
        
        # Issue 8: Validate timestamps are numeric before using them
        if [[ "$wal_failed_time" != "NULL" ]] && [[ "$wal_failed_time" =~ ^[0-9]+$ ]]; then
            PG_WAL_LAST_FAILED_TIME="$wal_failed_time"
        else
            PG_WAL_LAST_FAILED_TIME=""
        fi
        
        if [[ "$wal_stats_reset" != "NULL" ]] && [[ "$wal_stats_reset" =~ ^[0-9]+$ ]]; then
            PG_WAL_STATS_RESET="$wal_stats_reset"
        else
            PG_WAL_STATS_RESET=""
        fi
        
        if [[ "$wal_last_archived" != "NULL" ]] && [[ "$wal_last_archived" =~ ^[0-9]+$ ]]; then
            PG_WAL_LAST_ARCHIVED_TIME="$wal_last_archived"
        else
            PG_WAL_LAST_ARCHIVED_TIME=""
        fi
        
        # Calculate failure rate
        local total=$((PG_WAL_ARCHIVED_COUNT + PG_WAL_FAILED_COUNT))
        if [[ $total -gt 0 ]]; then
            PG_WAL_FAILURE_RATE=$(awk "BEGIN {printf \"%.1f\", ($PG_WAL_FAILED_COUNT / $total) * 100}")
        else
            PG_WAL_FAILURE_RATE="0.0"
        fi
        
        # Issue 8: Check if last failure was recent (within 24 hours) with proper validation
        if [[ -n "$PG_WAL_LAST_FAILED_TIME" ]] && [[ "$PG_WAL_LAST_FAILED_TIME" =~ ^[0-9]+$ ]]; then
            local now=$(date +%s)
            PG_WAL_LAST_FAILED_AGE=$((now - PG_WAL_LAST_FAILED_TIME))
        else
            PG_WAL_LAST_FAILED_AGE=999999999
        fi
    fi
}

# get_postgres_backup_stats
#
# Extracts all PostgreSQL backup statistics from pgBackRest info JSON
# Parses backup counts, timestamps, sizes, PITR range, WAL status, and pruning health
#
# Arguments:
#   $1 - JSON string from pgBackRest info command
#
# Globals Set:
#   PG_BACKUP_COUNT - Total number of backups
#   PG_LAST_FULL_TIME - Timestamp of last full backup
#   PG_LAST_FULL_LABEL - Label of last full backup
#   PG_LAST_DIFF_TIME - Timestamp of last differential backup
#   PG_LAST_DIFF_LABEL - Label of last differential backup
#   PG_LAST_BACKUP_TYPE - Type of most recent backup
#   PG_LAST_BACKUP_TIME - Timestamp of most recent backup
#   PG_LAST_BACKUP_SIZE - Size of most recent backup
#   PG_LAST_BACKUP_DELTA - Delta size of most recent backup
#   PG_OLDEST_BACKUP_TIME - Timestamp of oldest backup
#   PG_PRUNING_STATUS - Health status of pruning (Healthy/Warning)
#   PG_PRUNING_MESSAGE - Details if pruning has issues
#   PG_WAL_* - Various WAL archive statistics
#   PG_PITR_* - PITR range information
get_postgres_backup_stats() {
    local info="$1"
    
    # Backup counts and basic info
    PG_BACKUP_COUNT=$(echo "$info" | jq -r '.[0].backup | length')
    
    # Latest full backup
    local last_full=$(echo "$info" | jq -r '[.[0].backup[] | select(.type == "full")] | sort_by(.timestamp.stop) | last')
    PG_LAST_FULL_TIME=$(echo "$last_full" | jq -r '.timestamp.stop // empty')
    PG_LAST_FULL_LABEL=$(echo "$last_full" | jq -r '.label // empty')
    
    # Latest differential backup
    local last_diff=$(echo "$info" | jq -r '[.[0].backup[] | select(.type == "diff")] | sort_by(.timestamp.stop) | last')
    PG_LAST_DIFF_TIME=$(echo "$last_diff" | jq -r '.timestamp.stop // empty')
    PG_LAST_DIFF_LABEL=$(echo "$last_diff" | jq -r '.label // empty')
    
    # Latest backup (any type)
    local last_backup=$(echo "$info" | jq -r '.[0].backup | sort_by(.timestamp.stop) | last')
    PG_LAST_BACKUP_TYPE=$(echo "$last_backup" | jq -r '.type')
    PG_LAST_BACKUP_TIME=$(echo "$last_backup" | jq -r '.timestamp.stop')
    PG_LAST_BACKUP_SIZE=$(echo "$last_backup" | jq -r '.info.size // 0')
    PG_LAST_BACKUP_DELTA=$(echo "$last_backup" | jq -r '.info.delta // 0')
    
    # PITR range
    local oldest_backup=$(echo "$info" | jq -r '.[0].backup | sort_by(.timestamp.stop) | first')
    PG_OLDEST_BACKUP_TIME=$(echo "$oldest_backup" | jq -r '.timestamp.stop')
    
    # Check oldest backup age for pruning health (Issue 17)
    # RETENTION POLICY: This check uses constants from backups/config.sh
    #   PG_RETENTION_FULL_WEEKS, PG_EXPECTED_MAX_AGE_DAYS
    #   Must match policy in db/pgbackrest.conf repo1-retention-full setting
    local now=$(date +%s)
    local oldest_age_days=$(( (now - PG_OLDEST_BACKUP_TIME) / 86400 ))
    if (( oldest_age_days > PG_EXPECTED_MAX_AGE_DAYS )); then
        PG_PRUNING_STATUS="Warning"
        PG_PRUNING_MESSAGE="Oldest backup is ${oldest_age_days} days old (expected < ${PG_EXPECTED_MAX_AGE_DAYS} days)"
    else
        PG_PRUNING_STATUS="Healthy"
        PG_PRUNING_MESSAGE=""
    fi
    
    # WAL archive status
    local wal_max=$(echo "$info" | jq -r '.[0].archive[0].max // empty')
    if [[ -n "$wal_max" ]] && [[ "$wal_max" != "null" ]]; then
        PG_WAL_MAX="$wal_max"
        PG_WAL_STATUS="Active"
    else
        PG_WAL_MAX=""
        PG_WAL_STATUS="Unknown"
    fi
    
    # Backup age
    local now=$(date +%s)
    PG_BACKUP_AGE_SECONDS=$((now - PG_LAST_BACKUP_TIME))
    PG_BACKUP_AGE_HOURS=$((PG_BACKUP_AGE_SECONDS / 3600))
    
    # Get WAL archive statistics
    get_wal_archive_stats
    
    # Get WAL archive max from pgBackRest info
    PG_WAL_ARCHIVE_MAX=$(echo "$info" | jq -r '.[0].archive[0].max // empty')
    
    # Get last backup's archive stop for comparison
    local last_backup_archive_stop=$(echo "$last_backup" | jq -r '.archive.stop // empty')
    
    # Determine if PITR extends beyond last backup
    if [[ -n "$PG_WAL_ARCHIVE_MAX" ]] && [[ -n "$last_backup_archive_stop" ]] && [[ "$PG_WAL_ARCHIVE_MAX" > "$last_backup_archive_stop" ]]; then
        # WAL archive extends beyond last backup
        PG_PITR_EXTENDS_VIA_WAL=true
        PG_PITR_WAL_MAX="$PG_WAL_ARCHIVE_MAX"
        
        # Get the actual finalization time of the latest archived WAL
        local wal_finalization_time
        if wal_finalization_time=$(get_wal_finalization_time "$PG_WAL_ARCHIVE_MAX"); then
            # Use the actual WAL finalization time for accurate PITR end
            PG_PITR_END_TIME="$wal_finalization_time"
        else
            # Can't get WAL timestamp (stats likely reset) - be conservative
            # Use last backup time and note that WAL extends beyond it
            PG_PITR_END_TIME="$PG_LAST_BACKUP_TIME"
        fi
    else
        # PITR only extends to last backup
        PG_PITR_EXTENDS_VIA_WAL=false
        PG_PITR_END_TIME="$PG_LAST_BACKUP_TIME"
    fi
}

# display_postgres_status
#
# Displays PostgreSQL backup status to console with color formatting
#
# Arguments:
#   $1 - JSON info string from validate_postgres_backup_system
#
# Globals Used:
#   Color variables (RED, GREEN, YELLOW, BLUE, NC)
#   POSTGRES_DB_CONTAINER - Container name
#   Various PG_* variables set by get_postgres_backup_stats
#
# Returns:
#   0 if all checks pass, 1 if warnings detected
display_postgres_status() {
    local info="$1"
    
    echo -e "${BLUE}--- PostgreSQL (pgBackRest) ---${NC}"
    
    if ! validate_postgres_backup_system >/dev/null 2>&1; then
        echo -e "${RED}✗ Backup system validation failed${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Container: $POSTGRES_DB_CONTAINER is running${NC}\n"
    
    get_postgres_backup_stats "$info"
    
    # Display backup information
    if [[ -n "$PG_LAST_FULL_TIME" ]] && [[ "$PG_LAST_FULL_TIME" != "null" ]]; then
        echo -e "${GREEN}Last Full Backup:${NC}    $(date -d "@$PG_LAST_FULL_TIME" '+%Y-%m-%d %H:%M:%S') ($PG_LAST_FULL_LABEL)"
    else
        echo -e "${YELLOW}Last Full Backup:${NC}    None found"
    fi
    
    if [[ -n "$PG_LAST_DIFF_TIME" ]] && [[ "$PG_LAST_DIFF_TIME" != "null" ]]; then
        echo -e "${GREEN}Last Differential:${NC}   $(date -d "@$PG_LAST_DIFF_TIME" '+%Y-%m-%d %H:%M:%S') ($PG_LAST_DIFF_LABEL)"
    else
        echo -e "${YELLOW}Last Differential:${NC}   None found"
    fi
    
    echo -e "\n${GREEN}Latest Backup:${NC}       $(date -d "@$PG_LAST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S') (${PG_LAST_BACKUP_TYPE})"
    echo -e "${GREEN}Type:${NC}                ${PG_LAST_BACKUP_TYPE}"
    echo -e "${GREEN}Backup Size:${NC}         $(format_bytes $PG_LAST_BACKUP_SIZE)"
    echo -e "${GREEN}Delta Size:${NC}          $(format_bytes $PG_LAST_BACKUP_DELTA)"
    
    echo -e "\n${GREEN}PITR Recovery Range:${NC}"
    echo -e "  From: $(date -d "@$PG_OLDEST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S') (oldest backup stop)"
    if [[ "${PG_PITR_EXTENDS_VIA_WAL:-false}" == "true" ]]; then
        echo -e "  To:   $(date -d "@$PG_PITR_END_TIME" '+%Y-%m-%d %H:%M:%S') (via WAL ${PG_PITR_WAL_MAX})"
    else
        echo -e "  To:   $(date -d "@$PG_LAST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S') (last backup stop)"
    fi
    
    if [[ -n "$PG_WAL_MAX" ]]; then
        echo -e "\n${GREEN}✓ Latest WAL Archive:${NC}  $PG_WAL_MAX"
    else
        echo -e "\n${YELLOW}WAL Archive:${NC}         Status unknown"
    fi
    
    local oldest_age_days=$(( ($(date +%s) - PG_OLDEST_BACKUP_TIME) / 86400 ))
    if [[ "${PG_PRUNING_STATUS}" == "Warning" ]]; then
        echo -e "${YELLOW}⚠ Oldest Backup:${NC}     $(date -d "@$PG_OLDEST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S') (${oldest_age_days} days - pruning may not be working)"
    else
        echo -e "${GREEN}✓ Oldest Backup:${NC}     $(date -d "@$PG_OLDEST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S') (${oldest_age_days} days)"
    fi
    
    echo -e "${GREEN}✓ Total backups:${NC}     $PG_BACKUP_COUNT"
    echo -e "${GREEN}✓ S3 Repository:${NC}     OK (stanza: $POSTGRES_STANZA)"
    
    if ((PG_BACKUP_AGE_HOURS > 36)); then
        echo -e "\n${YELLOW}⚠ Warning: Last backup is ${PG_BACKUP_AGE_HOURS} hours old${NC}"
        return 1
    fi
    
    return 0
}
