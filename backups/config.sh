#!/bin/bash
# Centralized Backup System Configuration
# Source this file in all backup scripts for consistent settings

# Timezone (Issue 16)
export TZ="Australia/Perth"

# PostgreSQL Configuration (Issue 13)
export POSTGRES_DB_CONTAINER="${POSTGRES_DB_CONTAINER:-db}"
export POSTGRES_STANZA="${POSTGRES_STANZA:-main}"

# AWS/S3 Configuration
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"
export S3_BUCKET_PREFIX="jig-ho-cottage-dr"

# Restic Configuration
export FOUNDRY_RESTIC_REPO="s3:s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET_PREFIX}/pi-hosting/foundry"

# Prevent multiple sourcing
if [[ -n "${BACKUP_CONFIG_LOADED:-}" ]]; then
    return 0
fi
BACKUP_CONFIG_LOADED=1

# Timing Constants (Issue 17 - Extract Magic Numbers)
# All times in seconds unless otherwise noted
export MAX_DIFF_BACKUP_AGE=129600           # 36 hours (1.5 days buffer for daily diff backups)
export MAX_FULL_BACKUP_AGE=691200           # 8 days (weekly full backups with 1 day buffer)
export WAL_FAILURE_WINDOW=604800            # 7 days to check for WAL failures
export FOUNDRY_BACKUP_STALE_HOURS=30        # Hours before Foundry backup considered stale
export COMMAND_TIMEOUT=60                   # Timeout for external commands (seconds)

# Retention Policy Configuration (Issue 17)
# PostgreSQL: Must match db/pgbackrest.conf repo1-retention-full setting
export PG_RETENTION_FULL_WEEKS=52           # 52 weekly backups = ~364 days
export PG_EXPECTED_MAX_AGE_DAYS=400         # 52 weeks + ~5 weeks buffer

# Foundry: Must match backups/foundry/foundry-backup.sh retention policy
export FOUNDRY_RETENTION_DAILY=30           # Keep 30 daily snapshots
export FOUNDRY_RETENTION_MONTHLY=12         # Keep 12 monthly snapshots
export FOUNDRY_EXPECTED_MAX_AGE_DAYS=450    # ~14 months + ~1 month buffer

# Exit Codes (Issue 17)
export EXIT_SUCCESS=0
export EXIT_WARNING=1                       # Backups work but have warnings (stale, etc)
export EXIT_ERROR=2                         # Critical system errors
