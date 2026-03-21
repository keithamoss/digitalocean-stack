#!/bin/bash
#
# Configs Backup Script
# Backs up all secret/credential files to S3 using restic
#
# Retention Policy: 30 daily + monthly forever
#   - Never commit to git (all these files are git-ignored)
#   - Restic provides client-side encryption (same key as Foundry/Logs repos)
#
# Secrets directories backed up:
#   Auto-discovered: all secrets/ dirs under REPO_ROOT, except exclusions below.
#   New services are automatically included without script changes.
#
# Excluded directories (explicitly skipped by find):
#   - secrets/                 (root-level legacy, to be deleted)
#   - foundry-test/secrets/    (disposable test environment)
#   - secrets-tmpl/            (git-tracked templates, not real secrets)
#   - foundry/data/            (Foundry runtime data, not credentials)
#
# Excluded files:
#   - */templates/             (already in git)
#   - *.md, *.tmpl, .gitkeep  (documentation/placeholders/git-tracked templates)
#
# Extra individual files (not in secrets/ dirs):
#   - redis/conf/users.acl     (Redis ACL - password hashes, not in version control)
#
# Requirements:
# - restic installed
# - AWS credentials in backups/secrets/aws.env
# - Restic password in backups/secrets/restic.key
#

set -euo pipefail

# Determine script and backup directories using realpath
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$BACKUPS_DIR/..")"

# Load centralized configuration
source "${BACKUPS_DIR}/config.sh"

# error
#
# Logs an error message to stderr and exits
#
# Arguments:
#   $* - Error message
error() {
    echo "ERROR: $*" >&2
    exit 1
}

# Source AWS credentials
[[ -f "$BACKUPS_DIR/secrets/aws.env" ]] || error "AWS credentials file not found: $BACKUPS_DIR/secrets/aws.env"
source "$BACKUPS_DIR/secrets/aws.env"

# Set restic password
[[ -f "$BACKUPS_DIR/secrets/restic.key" ]] || error "Restic password file not found: $BACKUPS_DIR/secrets/restic.key"
export RESTIC_PASSWORD=$(cat "$BACKUPS_DIR/secrets/restic.key")

# Configuration - use centralized repo from config.sh
RESTIC_REPO="$CONFIGS_RESTIC_REPO"

echo "=========================================="
echo "Configs Backup - $(date)"
echo "=========================================="
echo "Repository: $RESTIC_REPO"
echo ""

# Auto-discover all secrets/ directories, excluding known non-secret paths.
# Adding a new service with a secrets/ dir will be picked up automatically.
mapfile -t SECRETS_PATHS < <(
    find "${REPO_ROOT}" -type d -name "secrets" \
        ! -path "${REPO_ROOT}/secrets" \
        ! -path "${REPO_ROOT}/secrets/*" \
        ! -path "${REPO_ROOT}/foundry-test/*" \
        ! -path "${REPO_ROOT}/secrets-tmpl" \
        ! -path "${REPO_ROOT}/secrets-tmpl/*" \
        ! -path "${REPO_ROOT}/foundry/data/*" \
        ! -path "*/.git/*" \
        | sort
)

# Individual files outside of secrets/ directories
EXTRA_FILES=(
    "${REPO_ROOT}/redis/conf/users.acl"
)

# Check which paths exist and report
echo "Secrets directories to be backed up:"
BACKUP_PATHS=()
for path in "${SECRETS_PATHS[@]}"; do
    if [[ -d "$path" ]]; then
        file_count=$(find "$path" -maxdepth 1 -type f \( -name "*.env" -o -name "*.key" \) ! -name "*.md" ! -name ".gitkeep" 2>/dev/null | wc -l || echo "0")
        echo "  + ${path} (${file_count} secret files)"
        BACKUP_PATHS+=("$path")
    else
        echo "  - ${path} (not found, skipping)"
    fi
done

echo "Extra files to be backed up:"
for file in "${EXTRA_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        echo "  + ${file}"
        BACKUP_PATHS+=("$file")
    else
        echo "  - ${file} (not found, skipping)"
    fi
done
echo ""

if [[ ${#BACKUP_PATHS[@]} -eq 0 ]]; then
    error "No valid secrets directories or files found to back up."
fi

# Verify restic repository is initialized
echo "Verifying restic repository..."
if ! restic -r "$RESTIC_REPO" snapshots --last 2>/dev/null >/dev/null; then
    error "Restic repository not initialized or not accessible. Run init-configs-backup.sh first."
fi
echo "✓ Repository verified"
echo ""

# Test S3 bucket accessibility before starting backup
echo "Testing S3 bucket accessibility..."
if ! restic -r "$RESTIC_REPO" stats --mode raw-data 2>/dev/null >/dev/null; then
    error "Cannot access S3 bucket or repository. Check AWS credentials and bucket permissions (Region: ${AWS_DEFAULT_REGION:-unknown})"
fi
echo "✓ S3 bucket accessible"
echo ""

# Run backup
echo "Starting backup..."
START_TIME=$(date +%s)

if restic -r "$RESTIC_REPO" backup \
    --tag configs \
    --tag daily \
    --host raspberrypi \
    --exclude="*/templates" \
    --exclude="*/templates/*" \
    --exclude="*.md" \
    --exclude="*.tmpl" \
    --exclude=".gitkeep" \
    "${BACKUP_PATHS[@]}"; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "Backup completed successfully in ${DURATION}s"

    # Show latest snapshot info
    echo ""
    echo "Latest snapshot:"
    restic -r "$RESTIC_REPO" snapshots --latest 1 --json | \
        jq -r '.[] | "  ID: \(.short_id)\n  Time: \(.time)\n  Hostname: \(.hostname)\n  Files: \((.files_new // 0) + (.files_changed // 0) + (.files_unmodified // 0)) (\(.files_new // 0) new, \(.files_changed // 0) changed)\n  Size: \(((.size_new // 0) + (.size_changed // 0) + (.size_unmodified // 0)) / 1024 | floor)KB (\((.size_new // 0) / 1024 | floor)KB new)"'

    # Apply retention policy from centralized config
    # IMPORTANT: If you change these values, also update backups/config.sh
    #   CONFIGS_RETENTION_DAILY and CONFIGS_RETENTION_MONTHLY constants
    echo ""
    echo "Applying retention policy (${CONFIGS_RETENTION_DAILY} daily, monthly forever)..."
    restic -r "$RESTIC_REPO" forget \
        --tag configs \
        --keep-daily "$CONFIGS_RETENTION_DAILY" \
        --keep-monthly "$CONFIGS_RETENTION_MONTHLY" \
        --prune

    echo ""
    echo "Repository statistics:"
    restic -r "$RESTIC_REPO" stats --json | \
        jq -r '"  Total size: \((.total_size // 0) / 1024 | floor)KB\n  Total file count: \(.total_file_count // 0)"'

    echo ""
    echo "=========================================="
    echo "✓ Configs backup completed successfully!"
    echo "=========================================="
    exit 0
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "✗ Backup failed after ${DURATION}s"
    echo "=========================================="
    exit 1
fi
