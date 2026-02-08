#!/bin/bash
#
# Initialize Foundry VTT Backup Repository
# Run this once to set up the restic repository in S3
#
# Prerequisites:
# - AWS credentials in backups/secrets/aws.env
# - Restic password in backups/secrets/restic.key
# - restic installed (via infra/setup.sh)
#

set -euo pipefail

# Determine script and backup directories using realpath (Issue 4)
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")" 
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$BACKUPS_DIR/..")"

# Load centralized configuration (Issue 3)
source "${BACKUPS_DIR}/config.sh"

echo "=========================================="
echo "Foundry VTT Backup Repository Setup"
echo "=========================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v restic >/dev/null 2>&1; then
    echo "ERROR: restic is not installed"
    echo "Run: sudo apt install restic"
    echo "Or: cd $REPO_ROOT/infra && sudo ./setup.sh"
    exit 1
fi

if [[ ! -f "$BACKUPS_DIR/secrets/aws.env" ]]; then
    echo "ERROR: AWS credentials not found at $BACKUPS_DIR/secrets/aws.env"
    echo "Create it from the template in $BACKUPS_DIR/secrets/templates/aws.env"
    exit 1
fi

if [[ ! -f "$BACKUPS_DIR/secrets/restic.key" ]]; then
    echo "ERROR: Restic password not found at $BACKUPS_DIR/secrets/restic.key"
    echo "Generate one with: openssl rand -base64 32 > $BACKUPS_DIR/secrets/restic.key"
    echo "Or run: cd $REPO_ROOT/infra && sudo ./setup.sh"
    exit 1
fi

echo "✓ restic installed: $(restic version | head -1)"
echo "✓ AWS credentials found"
echo "✓ Restic password found"
echo ""

# Load AWS credentials
source "$BACKUPS_DIR/secrets/aws.env"

# Set restic password
export RESTIC_PASSWORD=$(cat "$BACKUPS_DIR/secrets/restic.key")

# Configuration - use centralized repo from config.sh (Issue 3)
RESTIC_REPO="$FOUNDRY_RESTIC_REPO"

echo "Repository: $RESTIC_REPO"
echo ""

# Check if repository already exists
echo "Checking if repository exists..."
if restic -r "$RESTIC_REPO" snapshots >/dev/null 2>&1; then
    echo ""
    echo "⚠️  Repository already exists!"
    echo ""
    echo "Current snapshots:"
    restic -r "$RESTIC_REPO" snapshots
    echo ""
    read -p "Repository is already initialized. Nothing to do. Press Enter to exit..."
    exit 0
fi

# Initialize repository
echo "Initializing repository..."
echo ""

if restic -r "$RESTIC_REPO" init; then
    echo ""
    echo "=========================================="
    echo "✓ Repository initialized successfully!"
    echo "=========================================="
    echo ""
    echo "Repository: $RESTIC_REPO"
    echo "Encryption: AES-256"
    echo ""
    echo "IMPORTANT NEXT STEPS:"
    echo "1. ⚠️  BACKUP the encryption key to your password manager:"
    echo "   $BACKUPS_DIR/secrets/restic.key"
    echo ""
    echo "2. Run your first backup:"
    echo "   $SCRIPT_DIR/foundry-backup.sh"
    echo ""
    echo "3. Enable automated backups:"
    echo "   sudo systemctl enable foundry-backup.timer"
    echo "   sudo systemctl start foundry-backup.timer"
    echo ""
    echo "4. Verify schedule:"
    echo "   systemctl list-timers | grep foundry-backup"
    echo ""
else
    echo ""
    echo "ERROR: Failed to initialize repository"
    exit 1
fi
