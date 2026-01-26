#!/bin/bash
# PostgreSQL Backup Status Monitor
# Checks pgBackRest backup status and reports to console/Discord

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="${BACKUPS_DIR}/secrets"
DISCORD_ENV="${SECRETS_DIR}/discord.env"
DB_CONTAINER="db"
STANZA="main"

# Load Discord webhook if available
if [[ -f "$DISCORD_ENV" ]]; then
    source "$DISCORD_ENV"
fi

# Load shared Discord notification library
source "${SCRIPT_DIR}/discord-lib.sh"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to format bytes to human readable
format_bytes() {
    local bytes=$1
    if ((bytes < 1024)); then
        echo "${bytes}B"
    elif ((bytes < 1048576)); then
        echo "$((bytes / 1024))KB"
    elif ((bytes < 1073741824)); then
        echo "$((bytes / 1048576))MB"
    else
        echo "$((bytes / 1073741824))GB"
    fi
}

# Function to get backup info from pgBackRest
get_backup_info() {
    docker exec "$DB_CONTAINER" /usr/local/bin/pgbackrest-wrapper --stanza="$STANZA" --output=json info 2>/dev/null || {
        echo "ERROR: Failed to retrieve backup info"
        return 1
    }
}

# Function to validate backup system and return info JSON
validate_backup_system() {
    # Check container
    if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; then
        echo "ERROR: Container $DB_CONTAINER is not running" >&2
        return 1
    fi
    
    # Get and validate backup info
    local info
    if ! info=$(get_backup_info); then
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

# Function to extract all backup statistics from info JSON
# Sets global variables with stats for use by main() and heartbeat()
get_backup_stats() {
    local info="$1"
    
    # Backup counts and basic info
    BACKUP_COUNT=$(echo "$info" | jq -r '.[0].backup | length')
    
    # Latest full backup
    local last_full=$(echo "$info" | jq -r '[.[0].backup[] | select(.type == "full")] | sort_by(.timestamp.stop) | last')
    LAST_FULL_TIME=$(echo "$last_full" | jq -r '.timestamp.stop // empty')
    LAST_FULL_LABEL=$(echo "$last_full" | jq -r '.label // empty')
    
    # Latest differential backup
    local last_diff=$(echo "$info" | jq -r '[.[0].backup[] | select(.type == "diff")] | sort_by(.timestamp.stop) | last')
    LAST_DIFF_TIME=$(echo "$last_diff" | jq -r '.timestamp.stop // empty')
    LAST_DIFF_LABEL=$(echo "$last_diff" | jq -r '.label // empty')
    
    # Latest backup (any type)
    local last_backup=$(echo "$info" | jq -r '.[0].backup | sort_by(.timestamp.stop) | last')
    LAST_BACKUP_TYPE=$(echo "$last_backup" | jq -r '.type')
    LAST_BACKUP_TIME=$(echo "$last_backup" | jq -r '.timestamp.stop')
    LAST_BACKUP_SIZE=$(echo "$last_backup" | jq -r '.info.size // 0')
    LAST_BACKUP_DELTA=$(echo "$last_backup" | jq -r '.info.delta // 0')
    
    # PITR range
    local oldest_backup=$(echo "$info" | jq -r '.[0].backup | sort_by(.timestamp.stop) | first')
    OLDEST_BACKUP_TIME=$(echo "$oldest_backup" | jq -r '.timestamp.stop')
    
    # WAL archive status
    local wal_max=$(echo "$info" | jq -r '.[0].archive[0].max // empty')
    if [[ -n "$wal_max" ]] && [[ "$wal_max" != "null" ]]; then
        WAL_MAX="$wal_max"
        WAL_STATUS="Active"
    else
        WAL_MAX=""
        WAL_STATUS="Unknown"
    fi
    
    # Backup age
    local now=$(date +%s)
    BACKUP_AGE_SECONDS=$((now - LAST_BACKUP_TIME))
    BACKUP_AGE_HOURS=$((BACKUP_AGE_SECONDS / 3600))
}

# Main status check - console output
main() {
    echo -e "${BLUE}=== PostgreSQL Backup Status ===${NC}\n"
    
    local info
    if ! info=$(validate_backup_system); then
        echo -e "${RED}✗ Backup system validation failed${NC}"
        send_discord "Backup Status Check Failed" \
            "Cannot validate backup system.\n\n${info}" \
            15548997 "🚨"
        return 1
    fi
    
    echo -e "${GREEN}✓ Container: $DB_CONTAINER is running${NC}"
    
    get_backup_stats "$info"
    
    echo -e "${GREEN}✓ Total backups: $BACKUP_COUNT${NC}\n"
    
    # Display backup information
    if [[ -n "$LAST_FULL_TIME" ]] && [[ "$LAST_FULL_TIME" != "null" ]]; then
        echo -e "${GREEN}Last Full Backup:${NC}    $(date -d "@$LAST_FULL_TIME" '+%Y-%m-%d %H:%M:%S') ($LAST_FULL_LABEL)"
    else
        echo -e "${YELLOW}Last Full Backup:${NC}    None found"
    fi
    
    if [[ -n "$LAST_DIFF_TIME" ]] && [[ "$LAST_DIFF_TIME" != "null" ]]; then
        echo -e "${GREEN}Last Differential:${NC}   $(date -d "@$LAST_DIFF_TIME" '+%Y-%m-%d %H:%M:%S') ($LAST_DIFF_LABEL)"
    else
        echo -e "${YELLOW}Last Differential:${NC}   None found"
    fi
    
    echo -e "\n${GREEN}Latest Backup:${NC}       $(date -d "@$LAST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S') (${LAST_BACKUP_TYPE})"
    echo -e "${GREEN}Backup Size:${NC}         $(format_bytes $LAST_BACKUP_SIZE)"
    echo -e "${GREEN}Delta Size:${NC}          $(format_bytes $LAST_BACKUP_DELTA)"
    
    if [[ -n "$WAL_MAX" ]]; then
        echo -e "${GREEN}Latest WAL Archive:${NC}  $WAL_MAX"
    else
        echo -e "${YELLOW}WAL Archive:${NC}         Status unknown"
    fi
    
    echo -e "\n${GREEN}PITR Recovery Range:${NC}"
    echo -e "  From: $(date -d "@$OLDEST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S')"
    echo -e "  To:   $(date -d "@$LAST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S')"
    
    echo -e "\n${GREEN}S3 Repository:${NC}       OK (stanza: $STANZA)"
    
    if ((BACKUP_AGE_HOURS > 36)); then
        echo -e "\n${YELLOW}⚠ Warning: Last backup is ${BACKUP_AGE_HOURS} hours old${NC}"
        return 1
    fi
    
    echo -e "\n${GREEN}✓ Backup system operational${NC}"
    return 0
}

# Daily heartbeat function - Discord notification
heartbeat() {
    echo "Sending daily backup heartbeat to Discord..."
    
    local info
    if ! info=$(validate_backup_system 2>&1); then
        send_discord "Daily Heartbeat: System Check Failed" \
            "Backup system validation failed.\n\n**Error:** ${info}\n\n**Action Required:** Check backup system." \
            15548997 "🚨"
        return 1
    fi
    
    get_backup_stats "$info"
    
    # Format data for Discord
    local formatted_time=$(date -d "@$LAST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S')
    local formatted_size=$(format_bytes $LAST_BACKUP_SIZE)
    local pitr_from=$(date -d "@$OLDEST_BACKUP_TIME" '+%Y-%m-%d %H:%M')
    local pitr_to=$(date -d "@$LAST_BACKUP_TIME" '+%Y-%m-%d %H:%M')
    
    # Build status message
    local status_msg="**PostgreSQL Backup Status**\n\n"
    status_msg+="✓ System: \`pi-hosting\`\n"
    status_msg+="✓ Total backups: \`${BACKUP_COUNT}\`\n"
    
    if ((BACKUP_AGE_HOURS > 36)); then
        status_msg+="⚠ Last backup: \`${formatted_time}\` (**${BACKUP_AGE_HOURS}h ago**)\n"
    else
        status_msg+="✓ Last backup: \`${formatted_time}\` (${BACKUP_AGE_HOURS}h ago)\n"
    fi
    
    status_msg+="✓ Type: \`${LAST_BACKUP_TYPE}\`\n"
    status_msg+="✓ Size: \`${formatted_size}\`\n"
    status_msg+="✓ PITR Range: \`${pitr_from}\` → \`${pitr_to}\`\n"
    status_msg+="✓ WAL Archive: ${WAL_STATUS}\n"
    status_msg+="✓ S3 Repo: Operational"
    
    if ((BACKUP_AGE_HOURS > 36)); then
        status_msg+="\n\n**Warning:** Last backup is older than 36 hours."
        send_discord "Daily Heartbeat: Backup Stale" "$status_msg" 16776960 "⚠️"
        return 1
    else
        status_msg+="\n\nAll systems nominal."
        send_discord "Backup System Healthy" "$status_msg" 5763719 "✅"
    fi
    
    return 0
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
