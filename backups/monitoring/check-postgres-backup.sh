#!/bin/bash
# PostgreSQL Backup Status Check (pgBackRest)
# Provides functions to check and report PostgreSQL backup status
#
# This script is sourced by backup-status.sh, not run directly

# Configuration
POSTGRES_DB_CONTAINER="${POSTGRES_DB_CONTAINER:-db}"
POSTGRES_STANZA="${POSTGRES_STANZA:-main}"

# Function to get backup info from pgBackRest
get_postgres_backup_info() {
    docker exec "$POSTGRES_DB_CONTAINER" /usr/local/bin/pgbackrest-wrapper --stanza="$POSTGRES_STANZA" --output=json info 2>/dev/null || {
        echo "ERROR: Failed to retrieve backup info"
        return 1
    }
}

# Function to validate PostgreSQL backup system and return info JSON
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
    
    local backup_count=$(echo "$info" | jq -r '.[0].backup | length')
    if [[ "$backup_count" == "0" ]] || [[ "$backup_count" == "null" ]]; then
        echo "ERROR: No backups found" >&2
        return 1
    fi
    
    echo "$info"
}

# Function to get the last archived WAL timestamp from PostgreSQL
get_last_wal_archive_time() {
    local wal_time
    wal_time=$(docker exec "$POSTGRES_DB_CONTAINER" psql -U postgres -d postgres -t -A -c "SELECT EXTRACT(EPOCH FROM last_archived_time)::bigint FROM pg_stat_archiver WHERE last_archived_time IS NOT NULL;" 2>/dev/null)
    if [[ -n "$wal_time" ]] && [[ "$wal_time" != "" ]]; then
        echo "$wal_time"
    else
        echo ""
    fi
}

# Function to get WAL archive statistics
get_wal_archive_stats() {
    local stats
    stats=$(docker exec "$POSTGRES_DB_CONTAINER" psql -U postgres -d postgres -t -A -c "SELECT archived_count, failed_count, EXTRACT(EPOCH FROM last_failed_time)::bigint, EXTRACT(EPOCH FROM stats_reset)::bigint FROM pg_stat_archiver;" 2>/dev/null)
    if [[ -n "$stats" ]]; then
        PG_WAL_ARCHIVED_COUNT=$(echo "$stats" | cut -d'|' -f1)
        PG_WAL_FAILED_COUNT=$(echo "$stats" | cut -d'|' -f2)
        PG_WAL_LAST_FAILED_TIME=$(echo "$stats" | cut -d'|' -f3)
        PG_WAL_STATS_RESET=$(echo "$stats" | cut -d'|' -f4)
        
        # Calculate failure rate
        local total=$((PG_WAL_ARCHIVED_COUNT + PG_WAL_FAILED_COUNT))
        if [[ $total -gt 0 ]]; then
            PG_WAL_FAILURE_RATE=$(awk "BEGIN {printf \"%.1f\", ($PG_WAL_FAILED_COUNT / $total) * 100}")
        else
            PG_WAL_FAILURE_RATE="0.0"
        fi
        
        # Check if last failure was recent (within 24 hours)
        if [[ -n "$PG_WAL_LAST_FAILED_TIME" ]] && [[ "$PG_WAL_LAST_FAILED_TIME" != "" ]]; then
            local now=$(date +%s)
            PG_WAL_LAST_FAILED_AGE=$((now - PG_WAL_LAST_FAILED_TIME))
        else
            PG_WAL_LAST_FAILED_AGE=999999999
        fi
    fi
}

# Function to extract all PostgreSQL backup statistics from info JSON
# Sets global variables with stats for use by calling scripts
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
    
    # Get actual PITR end time from last archived WAL
    PG_LAST_WAL_ARCHIVE_TIME=$(get_last_wal_archive_time)
    if [[ -n "$PG_LAST_WAL_ARCHIVE_TIME" ]] && [[ "$PG_LAST_WAL_ARCHIVE_TIME" -gt "$PG_LAST_BACKUP_TIME" ]]; then
        PG_PITR_END_TIME="$PG_LAST_WAL_ARCHIVE_TIME"
    else
        PG_PITR_END_TIME="$PG_LAST_BACKUP_TIME"
    fi
}

# Function to display PostgreSQL backup status (console output)
display_postgres_status() {
    local info="$1"
    
    echo -e "${BLUE}--- PostgreSQL (pgBackRest) ---${NC}"
    
    if ! validate_postgres_backup_system >/dev/null 2>&1; then
        echo -e "${RED}✗ Backup system validation failed${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Container: $POSTGRES_DB_CONTAINER is running${NC}"
    
    get_postgres_backup_stats "$info"
    
    echo -e "${GREEN}✓ Total backups: $PG_BACKUP_COUNT${NC}\n"
    
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
    echo -e "${GREEN}Backup Size:${NC}         $(format_bytes $PG_LAST_BACKUP_SIZE)"
    echo -e "${GREEN}Delta Size:${NC}          $(format_bytes $PG_LAST_BACKUP_DELTA)"
    
    if [[ -n "$PG_WAL_MAX" ]]; then
        echo -e "${GREEN}Latest WAL Archive:${NC}  $PG_WAL_MAX"
    else
        echo -e "${YELLOW}WAL Archive:${NC}         Status unknown"
    fi
    
    echo -e "\n${GREEN}PITR Recovery Range:${NC}"
    echo -e "  From: $(date -d "@$PG_OLDEST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S')"
    echo -e "  To:   $(date -d "@$PG_PITR_END_TIME" '+%Y-%m-%d %H:%M:%S')"
    if [[ "$PG_PITR_END_TIME" -gt "$PG_LAST_BACKUP_TIME" ]]; then
        local extra_minutes=$(( (PG_PITR_END_TIME - PG_LAST_BACKUP_TIME) / 60 ))
        echo -e "        ${GREEN}(+${extra_minutes} min beyond last backup via WAL)${NC}"
    fi
    
    echo -e "\n${GREEN}S3 Repository:${NC}       OK (stanza: $POSTGRES_STANZA)"
    
    if ((PG_BACKUP_AGE_HOURS > 36)); then
        echo -e "\n${YELLOW}⚠ Warning: Last backup is ${PG_BACKUP_AGE_HOURS} hours old${NC}"
        return 1
    fi
    
    return 0
}
