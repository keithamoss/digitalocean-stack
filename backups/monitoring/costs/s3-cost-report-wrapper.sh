#!/bin/bash
# S3 Cost Report Wrapper
# Runs the monthly S3 cost report with Discord notification and file logging.
# Invoked by the s3-cost-report systemd timer (5th of each month at 04:30).

set -euo pipefail

# Determine directories
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BACKUPS_DIR="$(realpath "$SCRIPT_DIR/../..")"
STACK_DIR="$(realpath "$BACKUPS_DIR/..")"

# Load shared wrapper library (config.sh is loaded inside setup_wrapper)
source "${BACKUPS_DIR}/lib/wrapper-lib.sh"

# Setup logging infrastructure
LOG_DIR="$STACK_DIR/logs/backups/s3-cost-report"
setup_wrapper "$LOG_DIR" "s3-cost-report"

# Install timeout trap handler
install_timeout_trap

# Locate the report script
REPORT_SCRIPT="$SCRIPT_DIR/s3-cost-report.sh"

# Start logging
log "=== S3 Cost Report Started ==="
log "Log file: $LOG_FILE"
log ""

# Execute the report (--discord sends the embed, state is saved automatically)
if run_with_logging "S3 Cost Report" "$REPORT_SCRIPT" --discord; then
    exit $EXIT_SUCCESS
else
    exit $EXIT_ERROR
fi
