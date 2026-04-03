#!/bin/bash
# Restore Test Status Check
# Provides functions to check and report monthly restore-test status
#
# This script is sourced by backup-status.sh, not run directly
#
# Note: Configuration comes from centralized config.sh
# Expected globals from caller:
#   STACK_DIR - Repository root path
#   MONITORING_DIR - backups/monitoring path
#   RESTORE_TEST_STALE_DAYS - Staleness threshold in days
#   RESTORE_TEST_STALE_HOURS - Derived threshold for display/warnings

# validate_restore_test_system
#
# Validates restore-test orchestration logs and returns JSON info.
# The checker parses the latest run block from the most recent
# restore-test log and derives pass/fail + freshness status.
#
# Returns:
#   0 on success, 1 on failure
#   JSON string with restore-test metadata on stdout
#   Error messages on stderr
validate_restore_test_system() {
    local restore_log_dir="${STACK_DIR}/logs/restore/orchestration"

    if [[ ! -d "$restore_log_dir" ]]; then
        echo "ERROR: Restore-test log directory not found: $restore_log_dir" >&2
        return 1
    fi

    local latest_log
    latest_log=$(find "$restore_log_dir" -maxdepth 1 -name 'restore-test-*.log' -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [[ -z "$latest_log" ]] || [[ ! -f "$latest_log" ]]; then
        echo "ERROR: No restore-test logs found in $restore_log_dir" >&2
        return 1
    fi

    local start_line
    start_line=$(grep -n "=== Restore Test Run Started ===" "$latest_log" | tail -1 | cut -d: -f1 || true)
    if [[ -z "$start_line" ]] || [[ ! "$start_line" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Could not locate restore-test run marker in $latest_log" >&2
        return 1
    fi

    local run_block
    run_block=$(sed -n "${start_line},\$p" "$latest_log")

    local first_line
    first_line=$(echo "$run_block" | head -1)
    local run_time
    run_time=$(echo "$first_line" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
    if [[ -z "$run_time" ]]; then
        echo "ERROR: Could not parse restore-test run timestamp from $latest_log" >&2
        return 1
    fi

    local run_epoch
    if ! run_epoch=$(date -d "$run_time" +%s 2>/dev/null); then
        echo "ERROR: Failed to parse restore-test run timestamp: $run_time" >&2
        return 1
    fi

    local summary_line
    summary_line=$(echo "$run_block" | grep "Passed:" | tail -1 || true)
    if [[ -z "$summary_line" ]]; then
        echo "ERROR: Could not find restore-test summary line in latest run block" >&2
        return 1
    fi

    local parsed_counts
    parsed_counts=$(echo "$summary_line" | sed -n 's/.*Passed: \([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\1 \2/p')
    if [[ -z "$parsed_counts" ]]; then
        echo "ERROR: Failed to parse passed/total checks from summary: $summary_line" >&2
        return 1
    fi

    local passed_checks total_checks
    passed_checks=$(echo "$parsed_counts" | awk '{print $1}')
    total_checks=$(echo "$parsed_counts" | awk '{print $2}')

    if [[ ! "$passed_checks" =~ ^[0-9]+$ ]] || [[ ! "$total_checks" =~ ^[0-9]+$ ]] || ((total_checks == 0)); then
        echo "ERROR: Invalid check counts in summary: $summary_line" >&2
        return 1
    fi

    local duration_line
    duration_line=$(echo "$run_block" | grep "Total duration:" | tail -1 || true)
    local duration="unknown"
    if [[ -n "$duration_line" ]]; then
        duration="${duration_line#*Total duration: }"
    fi

    local result="Passed"
    if ((passed_checks < total_checks)); then
        result="Failed"
    fi

    local now age_hours age_days
    now=$(date +%s)
    age_hours=$(((now - run_epoch) / 3600))
    age_days=$(((now - run_epoch) / 86400))

    local freshness="Fresh"
    if ((age_days > RESTORE_TEST_STALE_DAYS)); then
        freshness="Stale"
    fi

    local status="Healthy"
    if [[ "$result" == "Failed" ]]; then
        status="Failed"
    elif [[ "$freshness" == "Stale" ]]; then
        status="Stale"
    fi

    jq -n \
        --arg run_time "$run_time" \
        --arg run_epoch "$run_epoch" \
        --arg result "$result" \
        --arg passed_checks "$passed_checks" \
        --arg total_checks "$total_checks" \
        --arg duration "$duration" \
        --arg age_hours "$age_hours" \
        --arg age_days "$age_days" \
        --arg freshness "$freshness" \
        --arg status "$status" \
        --arg log_file "$latest_log" \
        '{
            run_time: $run_time,
            run_epoch: $run_epoch,
            result: $result,
            passed_checks: $passed_checks,
            total_checks: $total_checks,
            duration: $duration,
            age_hours: $age_hours,
            age_days: $age_days,
            freshness: $freshness,
            status: $status,
            log_file: $log_file
        }'

    return 0
}

# get_restore_test_stats
#
# Parses restore-test info JSON and sets global variables.
#
# Arguments:
#   $1 - JSON string from validate_restore_test_system
#
# Globals Set:
#   RESTORE_TEST_* variables for status rendering and heartbeat logic
get_restore_test_stats() {
    local restore_test_info="$1"

    RESTORE_TEST_RUN_TIME=$(echo "$restore_test_info" | jq -r '.run_time')
    RESTORE_TEST_RUN_EPOCH=$(echo "$restore_test_info" | jq -r '.run_epoch')
    RESTORE_TEST_RESULT=$(echo "$restore_test_info" | jq -r '.result')
    RESTORE_TEST_PASSED_CHECKS=$(echo "$restore_test_info" | jq -r '.passed_checks')
    RESTORE_TEST_TOTAL_CHECKS=$(echo "$restore_test_info" | jq -r '.total_checks')
    RESTORE_TEST_DURATION=$(echo "$restore_test_info" | jq -r '.duration')
    RESTORE_TEST_AGE_HOURS=$(echo "$restore_test_info" | jq -r '.age_hours')
    RESTORE_TEST_AGE_DAYS=$(echo "$restore_test_info" | jq -r '.age_days')
    RESTORE_TEST_FRESHNESS=$(echo "$restore_test_info" | jq -r '.freshness')
    RESTORE_TEST_STATUS=$(echo "$restore_test_info" | jq -r '.status')
    RESTORE_TEST_LOG_FILE=$(echo "$restore_test_info" | jq -r '.log_file')

    if [[ "$RESTORE_TEST_STATUS" == "Healthy" ]]; then
        RESTORE_TEST_STATUS_EMOJI="✓"
    elif [[ "$RESTORE_TEST_STATUS" == "Stale" ]]; then
        RESTORE_TEST_STATUS_EMOJI="⚠"
    else
        RESTORE_TEST_STATUS_EMOJI="✗"
    fi
}

# display_restore_test_status
#
# Displays restore-test status to console with color formatting.
#
# Returns:
#   0 if healthy, 1 if stale or failed
display_restore_test_status() {
    echo -e "\n${BLUE}--- Restore Test (monthly) ---${NC}"

    local restore_test_info
    if ! restore_test_info=$(validate_restore_test_system 2>&1); then
        echo -e "${RED}✗ Restore-test validation failed${NC}"
        echo -e "${RED}${restore_test_info}${NC}"
        return 1
    fi

    get_restore_test_stats "$restore_test_info"

    if [[ "$RESTORE_TEST_STATUS" == "Healthy" ]]; then
        echo -e "${GREEN}✓ Status:${NC}             Healthy (${RESTORE_TEST_PASSED_CHECKS}/${RESTORE_TEST_TOTAL_CHECKS} checks passed)"
    elif [[ "$RESTORE_TEST_STATUS" == "Stale" ]]; then
        echo -e "${YELLOW}⚠ Status:${NC}             Stale (${RESTORE_TEST_AGE_DAYS}d since last test; threshold ${RESTORE_TEST_STALE_DAYS}d)"
    else
        echo -e "${RED}✗ Status:${NC}             Failed (${RESTORE_TEST_PASSED_CHECKS}/${RESTORE_TEST_TOTAL_CHECKS} checks passed)"
    fi

    echo -e "${GREEN}✓ Last run:${NC}           ${RESTORE_TEST_RUN_TIME}"
    echo -e "${GREEN}✓ Duration:${NC}           ${RESTORE_TEST_DURATION}"
    echo -e "${GREEN}✓ Latest log:${NC}         ${RESTORE_TEST_LOG_FILE}"

    if [[ "$RESTORE_TEST_STATUS" != "Healthy" ]]; then
        return 1
    fi

    return 0
}
