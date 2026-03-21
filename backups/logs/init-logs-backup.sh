#!/bin/bash
#
# Initialize Logs Backup Repository
# Run this once to set up the restic repository in S3
#
# Reuses the same encryption key as the Foundry backup (per plan)
#
# Prerequisites:
# - AWS credentials in backups/secrets/aws.env
# - Restic password in backups/secrets/restic.key
# - restic installed (via infra/setup.sh)
#

set -euo pipefail

# Determine script and backup directories using realpath
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$BACKUPS_DIR/..")"

# Load centralized configuration
source "${BACKUPS_DIR}/config.sh"

echo "=========================================="
echo "Logs Backup Repository Setup"
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
    echo "Reuse the same key as the Foundry backup (per the backup plan)"
    exit 1
fi

echo "✓ restic installed: $(restic version | head -1)"
echo "✓ AWS credentials found"
echo "✓ Restic password found (shared with Foundry backup)"
echo ""

# Load AWS credentials
source "$BACKUPS_DIR/secrets/aws.env"

# Set restic password
export RESTIC_PASSWORD=$(cat "$BACKUPS_DIR/secrets/restic.key")

# Configuration - use centralized repo from config.sh
RESTIC_REPO="$LOGS_RESTIC_REPO"

echo "Repository: $RESTIC_REPO"
echo "Encryption: Client-side via restic (same key as Foundry)"
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
echo "Initializing restic repository at $RESTIC_REPO ..."
restic -r "$RESTIC_REPO" init

echo ""
echo "✓ Repository initialized successfully!"
echo ""

# Verify by listing snapshots (should be empty)
echo "Verifying repository..."
restic -r "$RESTIC_REPO" snapshots
echo "✓ Repository verified (no snapshots yet, as expected)"
echo ""

echo "=========================================="
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Run first backup manually to verify:"
echo "     $SCRIPT_DIR/logs-backup.sh"
echo ""
echo "  2. Verify snapshot in S3:"
echo "     restic -r $RESTIC_REPO snapshots"
echo ""
echo "  3. Install and start the systemd timer:"
echo "     sudo $BACKUPS_DIR/install-systemd.sh"
echo "     sudo systemctl start logs-backup.timer"
echo "=========================================="
