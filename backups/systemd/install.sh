#!/bin/bash
#
# Install pgBackRest backup systemd timers
#
# This script installs systemd service and timer units for automated PostgreSQL backups
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SYSTEMD_DIR="/etc/systemd/system"

echo "Installing pgBackRest backup systemd units..."

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root or with sudo"
    exit 1
fi

# Copy service and timer files
echo "Copying service files..."
cp "${SCRIPT_DIR}/postgres-diff-backup.service" "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/postgres-diff-backup.timer" "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/postgres-full-backup.service" "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/postgres-full-backup.timer" "${SYSTEMD_DIR}/"

# Set proper permissions
echo "Setting permissions..."
chmod 644 "${SYSTEMD_DIR}/postgres-diff-backup.service"
chmod 644 "${SYSTEMD_DIR}/postgres-diff-backup.timer"
chmod 644 "${SYSTEMD_DIR}/postgres-full-backup.service"
chmod 644 "${SYSTEMD_DIR}/postgres-full-backup.timer"

# Reload systemd
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable timers (but don't start yet)
echo "Enabling timers..."
systemctl enable postgres-diff-backup.timer
systemctl enable postgres-full-backup.timer

echo ""
echo "✓ Installation complete!"
echo ""
echo "Backup schedule:"
echo "  - Differential backup: Daily at 3:00 AM"
echo "  - Full backup: Weekly on Sunday at 3:00 AM"
echo ""
echo "To start the timers now:"
echo "  sudo systemctl start postgres-diff-backup.timer"
echo "  sudo systemctl start postgres-full-backup.timer"
echo ""
echo "To check timer status:"
echo "  systemctl list-timers postgres-*"
echo ""
echo "To manually run a backup:"
echo "  sudo systemctl start postgres-diff-backup.service  # Differential"
echo "  sudo systemctl start postgres-full-backup.service   # Full"
echo ""
echo "To view backup logs:"
echo "  journalctl -u postgres-diff-backup.service -f"
echo "  journalctl -u postgres-full-backup.service -f"
echo ""
