#!/bin/bash
#
# Logs Backup S3 Setup Verification
# Run this once to verify S3 is accessible before the first sync
#
# Prerequisites:
# - aws CLI v2 installed (via infra/setup.sh)
# - AWS credentials in backups/secrets/aws.env
#

set -euo pipefail

# Determine script and backup directories using realpath
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$BACKUPS_DIR/..")"

# Load centralized configuration
source "${BACKUPS_DIR}/config.sh"

echo "=========================================="
echo "Logs Backup S3 Setup"
echo "=========================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: aws CLI is not installed"
    echo "Run: sudo $REPO_ROOT/infra/setup.sh"
    exit 1
fi

if [[ ! -f "$BACKUPS_DIR/secrets/aws.env" ]]; then
    echo "ERROR: AWS credentials not found at $BACKUPS_DIR/secrets/aws.env"
    echo "Create it from the template in $BACKUPS_DIR/secrets/templates/aws.env"
    exit 1
fi

echo "✓ aws CLI installed: $(aws --version 2>&1 | head -1)"
echo "✓ AWS credentials found"
echo ""

# Load AWS credentials
source "$BACKUPS_DIR/secrets/aws.env"

S3_DESTINATION="$LOGS_S3_PATH"
S3_BUCKET=$(echo "$S3_DESTINATION" | grep -oP 's3://\K[^/]+')

echo "S3 destination: $S3_DESTINATION"
echo ""

# Check S3 accessibility
echo "Testing S3 accessibility..."
if aws s3 ls "$S3_DESTINATION/" >/dev/null 2>&1; then
    echo "✓ S3 path accessible"
    echo ""
    echo "Existing content summary:"
    aws s3 ls --recursive --summarize "$S3_DESTINATION/" 2>/dev/null | tail -3 || echo "  (none)"
else
    echo "⚠️  S3 path not yet accessible or empty — this is expected on first run."
    echo "   Checking bucket-level access..."
    if ! aws s3 ls "s3://$S3_BUCKET/" >/dev/null 2>&1; then
        echo "ERROR: Cannot access S3 bucket: $S3_BUCKET"
        echo "Check AWS credentials and IAM permissions."
        exit 1
    fi
    echo "✓ Bucket accessible (no logs uploaded yet)"
fi

echo ""
echo "⚠️  S3 encryption reminder:"
echo "   Verify that the '${S3_BUCKET}' bucket has SSE-S3 or SSE-KMS enabled"
echo "   (AWS console: Bucket > Properties > Default encryption)."

echo ""
echo "=========================================="
echo "Setup verified!"
echo ""
echo "Next steps:"
echo "  1. Run first sync manually to verify:"
echo "     $SCRIPT_DIR/logs-backup.sh"
echo ""
echo "  2. Verify files in S3:"
echo "     aws s3 ls --recursive $S3_DESTINATION/ | head -20"
echo ""
echo "  3. Install and start the systemd timer:"
echo "     sudo $BACKUPS_DIR/install-systemd.sh"
echo "     sudo systemctl start logs-backup.timer"
echo "=========================================="
