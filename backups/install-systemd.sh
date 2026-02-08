#!/bin/bash
#
# Install pgBackRest backup systemd timers
#
# This script installs systemd service and timer units for automated PostgreSQL backups
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SYSTEMD_DIR="/etc/systemd/system"

# Stack directory is the parent of backups/
STACK_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Auto-detect stack user (owner of the stack directory)
STACK_USER=$(stat -c '%U' "$STACK_DIR")

echo "Installing backup systemd units..."
echo "  Stack directory: $STACK_DIR"
echo "  Stack user: $STACK_USER"
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root or with sudo"
    exit 1
fi

# Function to install service/timer with substitution
install_unit() {
    local src_file="$1"
    local dest_file="$2"
    
    echo "  Installing $(basename "$dest_file")..."
    sed -e "s|@STACK_DIR@|${STACK_DIR}|g" \
        -e "s|@STACK_USER@|${STACK_USER}|g" \
        "$src_file" > "$dest_file"
    chmod 644 "$dest_file"
}

# Install service and timer files
echo "Copying and configuring service files..."
install_unit "${SCRIPT_DIR}/postgres/diff/postgres-diff-backup.service" "${SYSTEMD_DIR}/postgres-diff-backup.service"
install_unit "${SCRIPT_DIR}/postgres/diff/postgres-diff-backup.timer" "${SYSTEMD_DIR}/postgres-diff-backup.timer"
install_unit "${SCRIPT_DIR}/postgres/full/postgres-full-backup.service" "${SYSTEMD_DIR}/postgres-full-backup.service"
install_unit "${SCRIPT_DIR}/postgres/full/postgres-full-backup.timer" "${SYSTEMD_DIR}/postgres-full-backup.timer"
install_unit "${SCRIPT_DIR}/monitoring/heartbeat/backup-heartbeat.service" "${SYSTEMD_DIR}/backup-heartbeat.service"
install_unit "${SCRIPT_DIR}/monitoring/heartbeat/backup-heartbeat.timer" "${SYSTEMD_DIR}/backup-heartbeat.timer"
install_unit "${SCRIPT_DIR}/foundry/foundry-backup.service" "${SYSTEMD_DIR}/foundry-backup.service"
install_unit "${SCRIPT_DIR}/foundry/foundry-backup.timer" "${SYSTEMD_DIR}/foundry-backup.timer"

# Install failure alert template service (with substitution)
install_unit "${SCRIPT_DIR}/monitoring/backup-failure-alert@.service" "${SYSTEMD_DIR}/backup-failure-alert@.service"

# Reload systemd
echo "Reloading systemd daemon..."
if ! systemctl daemon-reload; then
    echo "ERROR: Failed to reload systemd daemon" >&2
    exit 1
fi

# Issue 12: Enable timers with validation (but don't start yet)
echo "Enabling timers..."
FAILED_TIMERS=()

for timer in postgres-diff-backup.timer postgres-full-backup.timer backup-heartbeat.timer; do
    if systemctl enable "$timer"; then
        echo "  ✓ Enabled $timer"
    else
        echo "  ✗ Failed to enable $timer" >&2
        FAILED_TIMERS+=("$timer")
    fi
done

# Check if any timers failed to enable
if [[ ${#FAILED_TIMERS[@]} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: Failed to enable the following timers:" >&2
    for timer in "${FAILED_TIMERS[@]}"; do
        echo "  - $timer" >&2
    done
    exit 1
fi

echo ""
echo "✓ Installation complete!"
echo ""
echo "Stack configuration:"
echo "  Directory: $STACK_DIR"
echo "  User: $STACK_USER"
echo ""
echo "Backup schedule:"
echo "  - Differential backup: Daily at 3:00 AM"
echo "  - Full backup: Weekly on Sunday at 3:00 AM"
echo "  - Foundry backup: Daily at 3:10 AM"
echo "  - Daily heartbeat: Daily at 3:30 AM"
echo ""
echo "To start the timers now:"
echo "  sudo systemctl start postgres-diff-backup.timer"
echo "  sudo systemctl start postgres-full-backup.timer"
echo "  sudo systemctl start foundry-backup.timer"
echo "  sudo systemctl start backup-heartbeat.timer"
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
