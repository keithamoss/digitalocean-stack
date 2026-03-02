#!/bin/bash
#
# Wrapper script for Docker log export
# Logs to both systemd journal and log files
#

set -euo pipefail

# Source the wrapper library for common logging functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/wrapper-lib.sh"

# Configuration
LOG_DIR="${SCRIPT_DIR}/../../logs/backups/docker-logs"
LOG_FILE="${LOG_DIR}/docker-logs-export_$(date +%Y-%m-%d).log"
EXPORT_SCRIPT="${SCRIPT_DIR}/export-docker-logs.sh"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Start logging
{
    echo "=== Docker Logs Export Started at $(date) ==="
    echo "Log file: ${LOG_FILE}"
    echo ""
    
    # Run the export script
    if "${EXPORT_SCRIPT}" 2>&1; then
        echo ""
        echo "=== Docker Logs Export Completed Successfully at $(date) ==="
        exit 0
    else
        EXIT_CODE=$?
        echo ""
        echo "=== Docker Logs Export FAILED at $(date) with exit code ${EXIT_CODE} ==="
        exit ${EXIT_CODE}
    fi
} | tee -a "${LOG_FILE}"
