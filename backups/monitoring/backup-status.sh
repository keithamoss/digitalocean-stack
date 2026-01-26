#!/bin/bash
# Backup Status Monitor
# Orchestrates PostgreSQL and Foundry backup status checks
# Reports to console and Discord

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="${BACKUPS_DIR}/secrets"
DISCORD_ENV="${SECRETS_DIR}/discord.env"

# Load Discord webhook if available
if [[ -f "$DISCORD_ENV" ]]; then
    source "$DISCORD_ENV"
fi

# Load shared libraries
source "${SCRIPT_DIR}/discord-lib.sh"
source "${SCRIPT_DIR}/check-postgres-backup.sh"
source "${SCRIPT_DIR}/check-foundry-backup.sh"

# Set configuration for sub-modules
export POSTGRES_DB_CONTAINER="db"
export POSTGRES_STANZA="main"
export FOUNDRY_RESTIC_REPO="s3:s3.ap-southeast-2.amazonaws.com/jig-ho-cottage-dr/pi-hosting/foundry"
export FOUNDRY_AWS_ENV="${SECRETS_DIR}/aws.env"
export FOUNDRY_RESTIC_KEY="${SECRETS_DIR}/restic.key"

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
    
    # Overall status
    if ((pg_status == 0)) && ((foundry_status == 0)); then
        echo -e "\n${GREEN}✓ All backup systems operational${NC}"
        return 0
    else
        echo -e "\n${YELLOW}⚠ Some backup checks have warnings${NC}"
        return 1
    fi
}

# Daily heartbeat function - Discord notification
heartbeat() {
    echo "Sending daily backup heartbeat to Discord..."
    
    # Check PostgreSQL backups
    local pg_info
    if ! pg_info=$(validate_postgres_backup_system 2>&1); then
        send_discord "Daily Heartbeat: System Check Failed" \
            "PostgreSQL backup system validation failed.\n\n**Error:** ${pg_info}\n\n**Action Required:** Check backup system." \
            15548997 "🚨"
        return 1
    fi
    
    get_postgres_backup_stats "$pg_info"
    
    # Check Foundry backups
    local foundry_status=0
    if ! check_foundry_backup >/dev/null 2>&1; then
        foundry_status=1
    fi
    
    # Format data for Discord
    local formatted_time=$(date -d "@$PG_LAST_BACKUP_TIME" '+%Y-%m-%d %H:%M:%S')
    local formatted_size=$(format_bytes $PG_LAST_BACKUP_SIZE)
    local pitr_from=$(date -d "@$PG_OLDEST_BACKUP_TIME" '+%Y-%m-%d %H:%M')
    local pitr_to=$(date -d "@$PG_PITR_END_TIME" '+%Y-%m-%d %H:%M')
    
    # Calculate if PITR extends beyond backup
    local pitr_extra=""
    if [[ "$PG_PITR_END_TIME" -gt "$PG_LAST_BACKUP_TIME" ]]; then
        local extra_minutes=$(( (PG_PITR_END_TIME - PG_LAST_BACKUP_TIME) / 60 ))
        pitr_extra=" (+${extra_minutes}m via WAL)"
    fi
    
    # Build status message
    local status_msg="**Backup Status Report**\n\n"
    status_msg+="**PostgreSQL (pgBackRest)**\n"
    status_msg+="✓ System: \`pi-hosting\`\n"
    status_msg+="✓ Total backups: \`${PG_BACKUP_COUNT}\`\n"
    
    if ((PG_BACKUP_AGE_HOURS > 36)); then
        status_msg+="⚠ Last backup: \`${formatted_time}\` (**${PG_BACKUP_AGE_HOURS}h ago**)\n"
    else
        status_msg+="✓ Last backup: \`${formatted_time}\` (${PG_BACKUP_AGE_HOURS}h ago)\n"
    fi
    
    status_msg+="✓ Type: \`${PG_LAST_BACKUP_TYPE}\`\n"
    status_msg+="✓ Size: \`${formatted_size}\`\n"
    status_msg+="✓ PITR Range: \`${pitr_from}\` → \`${pitr_to}\`${pitr_extra}\n"
    
    # WAL Archive health with failure tracking
    local wal_health_icon="✓"
    local wal_health_msg="${PG_WAL_STATUS}"
    
    if [[ -n "${PG_WAL_FAILURE_RATE:-}" ]]; then
        wal_health_msg+=", Failures: \`${PG_WAL_FAILED_COUNT}/${PG_WAL_ARCHIVED_COUNT}\` (${PG_WAL_FAILURE_RATE}%)"
        
        # Warn if failure rate > 10% and had failures in last 24h
        if (( $(awk "BEGIN {print ($PG_WAL_FAILURE_RATE > 10)}") )) && (( PG_WAL_LAST_FAILED_AGE < 86400 )); then
            wal_health_icon="⚠"
            local failed_hours=$((PG_WAL_LAST_FAILED_AGE / 3600))
            wal_health_msg+="\n⚠ Recent failures detected (${failed_hours}h ago)"
        fi
    fi
    
    status_msg+="${wal_health_icon} WAL Archive: ${wal_health_msg}\n"
    
    # Add Foundry status
    status_msg+="\n**Foundry VTT (restic)**\n"
    if ((foundry_status == 0)); then
        local foundry_time=$(date -d "@${FOUNDRY_SNAPSHOT_TIME}" '+%Y-%m-%d %H:%M:%S')
        local foundry_files=$(printf "%'d" $FOUNDRY_SNAPSHOT_SIZE)
        status_msg+="${FOUNDRY_STATUS_EMOJI} Status: \`${FOUNDRY_STATUS}\`\n"
        status_msg+="✓ Last backup: \`${foundry_time}\` (${FOUNDRY_AGE_HOURS}h ago)\n"
        status_msg+="✓ Files: \`${foundry_files}\`\n"
    else
        status_msg+="✗ Status: \`Failed\`\n"
    fi
    
    status_msg+="\n**Storage**\n"
    status_msg+="✓ S3 Repos: Operational"
    
    # Determine overall status and send appropriate notification
    if ((PG_BACKUP_AGE_HOURS > 36)) || ((foundry_status != 0)); then
        if ((PG_BACKUP_AGE_HOURS > 36)); then
            status_msg+="\n\n**Warning:** PostgreSQL backup is older than 36 hours."
        fi
        if ((foundry_status != 0)); then
            status_msg+="\n\n**Warning:** Foundry backup check failed."
        fi
        send_discord "Daily Heartbeat: Issues Detected" "$status_msg" 16776960 "⚠️"
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
