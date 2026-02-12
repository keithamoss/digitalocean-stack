#!/bin/bash
# Shared Wrapper Functions Library
# Provides common functionality for backup wrapper scripts
# Source this file in wrapper scripts to reduce code duplication

# setup_wrapper
#
# Initializes logging infrastructure for backup wrappers
#
# Arguments:
#   $1 - LOG_DIR: Directory where log files should be stored
#   $2 - LOG_PREFIX: Prefix for log filename (e.g., "heartbeat", "backup")
#
# Globals Set:
#   LOG_FILE - Full path to the log file for this run
#   TEMP_OUTPUT - Path to temporary output file
#   START_TIME - Timestamp when wrapper started (for duration tracking)
#   TIMEOUT_FLAG - Path to file that indicates if timeout occurred
#
# Side Effects:
#   - Creates log directory if it doesn't exist
#   - Creates temporary file and sets up trap for cleanup
#   - Sets TZ environment variable
setup_wrapper() {
    local log_dir="$1"
    local log_prefix="$2"
    
    # Load centralized configuration
    local backups_dir="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
    source "${backups_dir}/config.sh"
    
    # Create log directory
    mkdir -p "$log_dir"
    
    # Set log file path with date
    LOG_FILE="${log_dir}/${log_prefix}-$(date +%Y-%m-%d).log"
    
    # Create temp file for output capture
    TEMP_OUTPUT=$(mktemp)
    
    # Create timeout flag file
    TIMEOUT_FLAG=$(mktemp)
    
    trap 'rm -f "$TEMP_OUTPUT" "$TIMEOUT_FLAG"' EXIT
    
    # Track start time for duration calculation (Issue 10)
    START_TIME=$(date +%s)
}

# log
#
# Logs a message to both systemd journal (stdout) and log file
# Automatically adds timestamp to each message
#
# Arguments:
#   $* - Message to log
#
# Globals Used:
#   LOG_FILE - Path to log file (must be set by setup_wrapper)
log() {
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# error
#
# Logs an error message to stderr and log file
#
# Arguments:
#   $* - Error message
error() {
    log "ERROR: $*" >&2
}

# run_with_logging
#
# Executes a command, capturing output to temp file and logging results
# Calculates and logs execution duration
#
# Arguments:
#   $1 - Backup type description (e.g., "PostgreSQL Full Backup", "Heartbeat Check")
#   $@ - Command and arguments to execute
#
# Globals Used:
#   TEMP_OUTPUT - Temporary file for output capture
#   LOG_FILE - Log file path
#   START_TIME - Start timestamp for duration calculation
#
# Returns:
#   Exit code from executed command
#
# Side Effects:
#   - Writes command output to TEMP_OUTPUT
#   - Appends output to LOG_FILE
#   - Logs success/failure message with duration
run_with_logging() {
    local backup_type="$1"
    shift
    local cmd=("$@")
    
    log "Executing: ${cmd[*]}"
    log ""
    
    local exit_code
    if "${cmd[@]}" > "$TEMP_OUTPUT" 2>&1; then
        exit_code=0
        cat "$TEMP_OUTPUT" | tee -a "$LOG_FILE"
        
        # Calculate duration (Issue 10)
        local end_time=$(date +%s)
        local duration=$((end_time - START_TIME))
        
        log ""
        log "✓ ${backup_type} completed successfully"
        log "Duration: $(format_duration $duration)"
    else
        exit_code=$?
        cat "$TEMP_OUTPUT" | tee -a "$LOG_FILE"
        
        # Calculate duration (Issue 10)
        local end_time=$(date +%s)
        local duration=$((end_time - START_TIME))
        
        log ""
        log "✗ ${backup_type} failed with exit code ${exit_code}"
        log "Duration: $(format_duration $duration)"
    fi
    
    return $exit_code
}

# format_duration
#
# Formats seconds into human-readable duration string
#
# Arguments:
#   $1 - Duration in seconds
#
# Output:
#   Human-readable duration (e.g., "2h 15m 30s", "45m 12s", "23s")
format_duration() {
    local total_seconds=$1
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    
    if ((hours > 0)); then
        printf "%dh %dm %ds" $hours $minutes $seconds
    elif ((minutes > 0)); then
        printf "%dm %ds" $minutes $seconds
    else
        printf "%ds" $seconds
    fi
}

# handle_timeout
#
# Signal handler for SIGTERM (systemd timeout)
# Logs timeout information and marks the run as timed out
#
# Globals Used:
#   LOG_FILE - Log file path
#   TIMEOUT_FLAG - Path to timeout flag file
#   START_TIME - Start timestamp
handle_timeout() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    
    # Mark that we timed out
    echo "TIMEOUT" > "$TIMEOUT_FLAG"
    
    # Log the timeout
    log ""
    log "⏱ TIMEOUT: Systemd killed this job after $(format_duration $duration)"
    log "The backup process exceeded the configured timeout limit"
    
    # Exit with error code
    exit $EXIT_ERROR
}

# install_timeout_trap
#
# Installs the SIGTERM handler to catch systemd timeouts
# Should be called in wrapper scripts after setup_wrapper
install_timeout_trap() {
    trap 'handle_timeout' TERM
}

# check_for_timeout
#
# Checks if the most recent backup run timed out
#
# Arguments:
#   $1 - LOG_FILE path to check
#
# Returns:
#   0 if timeout detected, 1 if no timeout
#
# Output:
#   Prints timeout message if found
check_for_timeout() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        return 1
    fi
    
    # Check for timeout marker in last 50 lines
    if tail -50 "$log_file" 2>/dev/null | grep -q "⏱ TIMEOUT:"; then
        # Extract the timeout message
        tail -50 "$log_file" | grep "⏱ TIMEOUT:" | tail -1
        return 0
    fi
    
    return 1
}
