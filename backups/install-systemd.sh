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
install_unit "${SCRIPT_DIR}/docker/docker-logs-export.service" "${SYSTEMD_DIR}/docker-logs-export.service"
install_unit "${SCRIPT_DIR}/docker/docker-logs-export.timer" "${SYSTEMD_DIR}/docker-logs-export.timer"
install_unit "${STACK_DIR}/infra/db/postgresql-log-archive.service" "${SYSTEMD_DIR}/postgresql-log-archive.service"
install_unit "${STACK_DIR}/infra/db/postgresql-log-archive.timer" "${SYSTEMD_DIR}/postgresql-log-archive.timer"
install_unit "${STACK_DIR}/infra/backups/backups-log-archive.service" "${SYSTEMD_DIR}/backups-log-archive.service"
install_unit "${STACK_DIR}/infra/backups/backups-log-archive.timer" "${SYSTEMD_DIR}/backups-log-archive.timer"

# Install failure alert template service (with substitution)
install_unit "${SCRIPT_DIR}/monitoring/backup-failure-alert@.service" "${SYSTEMD_DIR}/backup-failure-alert@.service"

# Reload systemd
echo "Reloading systemd daemon..."
if ! systemctl daemon-reload; then
    echo "ERROR: Failed to reload systemd daemon" >&2
    exit 1
fi

# Issue 12: Enable timers with validation
# Note: Timers are enabled but not started to avoid triggering backups during installation.
# They will start automatically on next reboot. To start them now, run:
#   sudo systemctl start <timer-name>
echo "Enabling timers..."
FAILED_TIMERS=()

for timer in postgres-diff-backup.timer postgres-full-backup.timer foundry-backup.timer docker-logs-export.timer backup-heartbeat.timer postgresql-log-archive.timer backups-log-archive.timer; do
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

# Create log directories and grant the stack user full access (read, write, delete).
# Default ACLs ensure future files created by root/systemd automatically inherit access.
echo "Setting up log directories..."
mkdir -p \
    "$STACK_DIR/logs/backups/postgres-full" \
    "$STACK_DIR/logs/backups/postgres-diff" \
    "$STACK_DIR/logs/backups/foundry" \
    "$STACK_DIR/logs/backups/heartbeat" \
    "$STACK_DIR/logs/backups/docker-logs" \
    "$STACK_DIR/logs/docker" \
    "$STACK_DIR/logs/db/postgresql/archive"
# Capital X: sets execute on directories but not regular files (preserves correct file modes).
setfacl -R -m u:"$STACK_USER":rwX "$STACK_DIR/logs/backups" "$STACK_DIR/logs/docker"
# Default ACL on every directory so future root-created files inherit access.
find "$STACK_DIR/logs/backups" "$STACK_DIR/logs/docker" -type d -exec setfacl -d -m u:"$STACK_USER":rwx {} +
echo "  ✓ Log directories created and ACLs applied for $STACK_USER"

echo ""
echo "✓ Installation complete! All timers are enabled."
echo ""
echo "Stack configuration:"
echo "  Directory: $STACK_DIR"
echo "  User: $STACK_USER"
echo ""
echo "Backup schedule:"
echo "  - Differential backup: Daily at 3:00 AM"
echo "  - Full backup: Weekly on Sunday at 3:00 AM"
echo "  - Foundry backup: Daily at 3:10 AM"
echo "  - Docker logs export: Daily at 3:15 AM"
echo "  - Daily heartbeat: Daily at 3:30 AM"
echo ""
echo "Log maintenance schedule:"
echo "  - PostgreSQL log archive: Daily at 00:20 (compress + move to archive/)"
echo "  - Backup log archive:      Daily at 23:55 (compress + move to archive/)"
echo ""
echo "IMPORTANT: Timers are enabled but not started to avoid triggering backups during installation."
echo "They will start automatically on next reboot, or you can start them now:"
echo "  sudo systemctl start postgres-diff-backup.timer postgres-full-backup.timer foundry-backup.timer docker-logs-export.timer backup-heartbeat.timer postgresql-log-archive.timer backups-log-archive.timer"
echo ""
echo "To check timer status:"
echo "  systemctl list-timers"
echo ""
echo "To manually run a backup:"
echo "  sudo systemctl start postgres-diff-backup.service  # Differential"
echo "  sudo systemctl start postgres-full-backup.service   # Full"
echo ""
echo "To view backup logs:"
echo "  journalctl -u postgres-diff-backup.service -f"
echo "  journalctl -u postgres-full-backup.service -f"
echo ""
