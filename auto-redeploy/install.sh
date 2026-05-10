#!/bin/bash
#
# Install auto-redeploy systemd units, main script, and log directory.
# Usage: sudo ./auto-redeploy/install.sh
# Pattern: same as backups/install-systemd.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEMD_DIR="/etc/systemd/system"
INSTALL_BIN="/usr/local/bin/auto-redeploy.sh"

# Auto-detect stack user (owner of the stack directory)
STACK_USER=$(stat -c '%U' "$STACK_DIR")

echo "Installing auto-redeploy..."
echo "  Stack directory: $STACK_DIR"
echo "  Stack user:      $STACK_USER"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root or with sudo" >&2
    exit 1
fi

# Install main script — substitute @STACK_DIR@ token, then make executable
echo "Installing script to $INSTALL_BIN..."
sed "s|@STACK_DIR@|${STACK_DIR}|g" "${SCRIPT_DIR}/auto-redeploy.sh" > "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
chown root:root "$INSTALL_BIN"
echo "  ✓ Script installed: $INSTALL_BIN"

# Install systemd units with @STACK_DIR@ and @STACK_USER@ substitution
install_unit() {
    local src="$1" dest="$2"
    echo "  Installing $(basename "$dest")..."
    sed \
        -e "s|@STACK_DIR@|${STACK_DIR}|g" \
        -e "s|@STACK_USER@|${STACK_USER}|g" \
        "$src" > "$dest"
    chmod 644 "$dest"
}

echo "Installing systemd units..."
install_unit "${SCRIPT_DIR}/auto-redeploy.service" "${SYSTEMD_DIR}/auto-redeploy.service"
install_unit "${SCRIPT_DIR}/auto-redeploy.timer"   "${SYSTEMD_DIR}/auto-redeploy.timer"

# Reload systemd to pick up new units
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable the timer (not started here — done manually or on reboot)
echo "Enabling timer..."
systemctl enable auto-redeploy.timer
echo "  ✓ auto-redeploy.timer enabled"

# Install logrotate configs
echo "Installing logrotate configs..."
"${STACK_DIR}/infra/logrotate.d/deploy-logrotate.sh"

# Create log directory and grant the stack user full access via ACLs
# (same pattern as backups/install-systemd.sh)
echo "Setting up log directory..."
mkdir -p "${STACK_DIR}/logs/auto-redeploy"
# Capital X: sets execute on directories but not regular files
setfacl -m u:"${STACK_USER}":rwX "${STACK_DIR}/logs/auto-redeploy"
# Default ACL so future files created by root/systemd inherit access
setfacl -d -m u:"${STACK_USER}":rwx "${STACK_DIR}/logs/auto-redeploy"
echo "  ✓ Log directory ready: ${STACK_DIR}/logs/auto-redeploy"

echo ""
echo "✓ Auto-redeploy installed!"
echo ""
echo "Stack configuration:"
echo "  Directory: $STACK_DIR"
echo "  User:      $STACK_USER"
echo ""
echo "IMPORTANT: The timer is enabled but NOT started."
echo "Start it now or it will start automatically on next reboot:"
echo "  sudo systemctl start auto-redeploy.timer"
echo ""
echo "To check status:"
echo "  systemctl status auto-redeploy.timer"
echo "  journalctl -u auto-redeploy.service -f"
echo "  tail -f ${STACK_DIR}/logs/auto-redeploy/auto-redeploy.log"
