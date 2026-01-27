#!/bin/bash
# Send Discord failure alert for backup failures
# Called by systemd services when backups fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="${BACKUPS_DIR}/secrets"
DISCORD_ENV="${SECRETS_DIR}/discord.env"

BACKUP_TYPE="${1:-Unknown Backup}"
EXIT_CODE="${2:-1}"

# Load Discord webhook
if [[ ! -f "$DISCORD_ENV" ]]; then
    echo "Discord webhook not configured at $DISCORD_ENV"
    exit 0
fi

source "$DISCORD_ENV"

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
    echo "DISCORD_WEBHOOK_URL not set"
    exit 0
fi

# Load shared Discord notification library
source "${SCRIPT_DIR}/discord-lib.sh"

# Build failure message
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

DESCRIPTION="**${BACKUP_TYPE} Failed**\n\n"
DESCRIPTION+="**System:** \`${HOSTNAME}\`\n"
DESCRIPTION+="**Exit Code:** \`${EXIT_CODE}\`\n"
DESCRIPTION+="**Time:** ${TIMESTAMP}\n\n"
DESCRIPTION+="**Action Required:** Check logs with:\n"
DESCRIPTION+="\`\`\`\n"

# Adjust log command based on backup type
if [[ "$BACKUP_TYPE" =~ "Foundry" ]]; then
    DESCRIPTION+="journalctl -u foundry-backup.service -n 50\n"
elif [[ "$BACKUP_TYPE" =~ "PostgreSQL" ]] || [[ "$BACKUP_TYPE" =~ "postgres" ]]; then
    DESCRIPTION+="journalctl -u postgres-*-backup.service -n 50\n"
else
    DESCRIPTION+="journalctl -u *backup.service -n 50\n"
fi

DESCRIPTION+="\`\`\`"

# Send notification using shared function
if send_discord "Backup Failed" "$DESCRIPTION" 15548997 "🚨"; then
    echo "Discord failure alert sent for ${BACKUP_TYPE}"
else
    echo "Failed to send Discord notification"
    exit 1
fi
