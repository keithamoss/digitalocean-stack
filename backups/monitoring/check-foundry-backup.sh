#!/bin/bash
# Foundry VTT Backup Status Check (restic)
# Provides functions to check and report Foundry backup status
#
# This script is sourced by backup-status.sh, not run directly

# Configuration
FOUNDRY_RESTIC_REPO="${FOUNDRY_RESTIC_REPO:-s3:s3.ap-southeast-2.amazonaws.com/jig-ho-cottage-dr/pi-hosting/foundry}"
FOUNDRY_AWS_ENV="${FOUNDRY_AWS_ENV:-}"
FOUNDRY_RESTIC_KEY="${FOUNDRY_RESTIC_KEY:-}"

# Function to check Foundry backup status
check_foundry_backup() {
    # Load AWS credentials
    if [[ ! -f "$FOUNDRY_AWS_ENV" ]]; then
        echo "ERROR: AWS credentials not found" >&2
        return 1
    fi
    source "$FOUNDRY_AWS_ENV"
    
    # Load restic password
    if [[ ! -f "$FOUNDRY_RESTIC_KEY" ]]; then
        echo "ERROR: Restic key not found" >&2
        return 1
    fi
    export RESTIC_PASSWORD=$(cat "$FOUNDRY_RESTIC_KEY")
    
    # Get snapshots
    local snapshots
    if ! snapshots=$(restic -r "$FOUNDRY_RESTIC_REPO" snapshots --json --latest 1 2>&1); then
        echo "ERROR: Failed to query restic repository: $snapshots" >&2
        return 1
    fi
    
    # Check if we have any snapshots
    local snapshot_count=$(echo "$snapshots" | jq '. | length')
    if [[ "$snapshot_count" == "0" ]]; then
        echo "ERROR: No Foundry backups found" >&2
        return 1
    fi
    
    # Extract latest snapshot info
    FOUNDRY_SNAPSHOT_ID=$(echo "$snapshots" | jq -r '.[0].short_id')
    FOUNDRY_SNAPSHOT_TIME=$(echo "$snapshots" | jq -r '.[0].time' | xargs -I {} date -d {} +%s)
    FOUNDRY_SNAPSHOT_SIZE=$(echo "$snapshots" | jq -r '.[0].summary.total_files_processed // 0')
    
    # Calculate age
    local now=$(date +%s)
    FOUNDRY_AGE_SECONDS=$((now - FOUNDRY_SNAPSHOT_TIME))
    FOUNDRY_AGE_HOURS=$((FOUNDRY_AGE_SECONDS / 3600))
    
    # Determine status
    if ((FOUNDRY_AGE_HOURS > 36)); then
        FOUNDRY_STATUS="Stale"
        FOUNDRY_STATUS_EMOJI="⚠"
    else
        FOUNDRY_STATUS="Healthy"
        FOUNDRY_STATUS_EMOJI="✓"
    fi
    
    return 0
}

# Function to display Foundry backup status (console output)
display_foundry_status() {
    echo -e "\n${BLUE}--- Foundry VTT (restic) ---${NC}"
    
    if check_foundry_backup 2>/dev/null; then
        if [[ "$FOUNDRY_STATUS" == "Healthy" ]]; then
            echo -e "${GREEN}✓ Status:${NC}             $FOUNDRY_STATUS"
        else
            echo -e "${YELLOW}⚠ Status:${NC}             $FOUNDRY_STATUS (${FOUNDRY_AGE_HOURS}h since last backup)"
        fi
        echo -e "${GREEN}✓ Last backup:${NC}        $(date -d "@$FOUNDRY_SNAPSHOT_TIME" '+%Y-%m-%d %H:%M:%S')"
        echo -e "${GREEN}✓ Files backed up:${NC}    $(printf "%'d" $FOUNDRY_SNAPSHOT_SIZE)"
        
        if [[ "$FOUNDRY_STATUS" != "Healthy" ]]; then
            return 1
        fi
        return 0
    else
        echo -e "${RED}✗ Foundry backup check failed${NC}"
        return 1
    fi
}
