#!/bin/bash
# S3 Cost Status Check
# Provides functions to check and report S3 cost baseline status.
#
# This script is sourced by backup-status.sh, not run directly.
# It reads from the state file written by:
#   backups/monitoring/costs/s3-cost-report.sh
#
# Run the cost report first to populate the state file:
#   ./backups/monitoring/costs/s3-cost-report.sh
#
# Globals Used (set by caller/config.sh):
#   MONITORING_DIR   - backups/monitoring path
#   S3_COST_STALE_DAYS - Days before cost report is considered stale

# validate_s3_costs_system
#
# Reads the S3 cost state file and returns structured JSON.
# Returns an error if the state file does not exist yet.
#
# Returns:
#   0 on success, 1 on failure
#   JSON string with cost metadata on stdout
#   Error messages on stderr
validate_s3_costs_system() {
    local state_file="${MONITORING_DIR}/state/s3-costs-latest.json"

    if [[ ! -f "$state_file" ]]; then
        echo "ERROR: Cost state file not found: $state_file" >&2
        echo "Run the cost report to populate: backups/monitoring/costs/s3-cost-report.sh" >&2
        return 1
    fi

    local state
    if ! state=$(cat "$state_file"); then
        echo "ERROR: Failed to read cost state file: $state_file" >&2
        return 1
    fi

    if ! echo "$state" | jq empty 2>/dev/null; then
        echo "ERROR: Cost state file contains invalid JSON: $state_file" >&2
        return 1
    fi

    # Validate required keys exist
    local report_epoch
    report_epoch=$(echo "$state" | jq -r '.report_epoch // empty')
    if [[ -z "$report_epoch" ]] || [[ ! "$report_epoch" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Cost state file is missing report_epoch: $state_file" >&2
        return 1
    fi

    # Add freshness metadata
    local now age_days
    now=$(date +%s)
    age_days=$(( (now - report_epoch) / 86400 ))
    local freshness="Fresh"
    if ((age_days > S3_COST_STALE_DAYS)); then
        freshness="Stale"
    fi

    # Append freshness and age_days to state
    echo "$state" | jq \
        --argjson age_days "$age_days" \
        --arg freshness "$freshness" \
        '. + {age_days: $age_days, freshness: $freshness}'

    return 0
}

# get_s3_costs_stats
#
# Parses cost info JSON and sets global variables for use in
# backup-status.sh console output and heartbeat Discord messages.
#
# Arguments:
#   $1 - JSON string from validate_s3_costs_system
#
# Globals Set:
#   S3_COST_REPORT_DATE         - Human-readable report date
#   S3_COST_TOTAL_AUD           - Estimated total monthly cost
#   S3_COST_BUDGET_AUD_VAL      - Budget target (AUD)
#   S3_COST_BUDGET_STATUS       - under / near / over
#   S3_COST_TOTAL_BYTES         - Total storage in bytes
#   S3_COST_TOTAL_OBJECTS       - Total object count
#   S3_COST_AGE_DAYS            - Days since last report
#   S3_COST_FRESHNESS           - Fresh / Stale
#   S3_COST_DATABASE_AUD        - Estimated cost for database prefix
#   S3_COST_FOUNDRY_AUD         - Estimated cost for foundry prefix
#   S3_COST_LOGS_AUD            - Estimated cost for logs prefix
#   S3_COST_CONFIGS_AUD         - Estimated cost for configs prefix
get_s3_costs_stats() {
    local info="$1"

    S3_COST_REPORT_DATE=$(echo "$info"   | jq -r '.report_date')
    S3_COST_TOTAL_AUD=$(echo "$info"     | jq -r '.estimated_total_aud')
    S3_COST_BUDGET_AUD_VAL=$(echo "$info"| jq -r '.budget_aud')
    S3_COST_BUDGET_STATUS=$(echo "$info" | jq -r '.budget_status')
    S3_COST_TOTAL_BYTES=$(echo "$info"   | jq -r '.total_size_bytes')
    S3_COST_TOTAL_OBJECTS=$(echo "$info" | jq -r '.total_objects')
    S3_COST_AGE_DAYS=$(echo "$info"      | jq -r '.age_days')
    S3_COST_FRESHNESS=$(echo "$info"     | jq -r '.freshness')

    S3_COST_DATABASE_AUD=$(echo "$info"  | jq -r '.services.database.estimated_cost_aud // 0')
    S3_COST_FOUNDRY_AUD=$(echo "$info"   | jq -r '.services.foundry.estimated_cost_aud // 0')
    S3_COST_LOGS_AUD=$(echo "$info"      | jq -r '.services.logs.estimated_cost_aud // 0')
    S3_COST_CONFIGS_AUD=$(echo "$info"   | jq -r '.services.configs.estimated_cost_aud // 0')
}

# display_s3_costs_status
#
# Displays S3 cost status to console with color formatting.
# If no state file exists, shows a reminder to run the cost report.
#
# Returns:
#   0 if healthy / fresh
#   1 if stale or state file missing
display_s3_costs_status() {
    echo -e "\n${BLUE}--- S3 Cost Baseline (Phase 6A) ---${NC}"

    local cost_info
    if ! cost_info=$(validate_s3_costs_system 2>&1); then
        echo -e "${YELLOW}ℹ  No cost report yet.${NC}"
        echo -e "${YELLOW}   Run: backups/monitoring/costs/s3-cost-report.sh${NC}"
        return 1
    fi

    get_s3_costs_stats "$cost_info"

    # Budget status icon
    local budget_icon budget_label
    case "$S3_COST_BUDGET_STATUS" in
        under) budget_icon="${GREEN}✓${NC}"; budget_label="under budget" ;;
        near)  budget_icon="${YELLOW}⚠${NC}"; budget_label="approaching budget" ;;
        over)  budget_icon="${RED}✗${NC}";  budget_label="OVER BUDGET" ;;
        *)     budget_icon="${YELLOW}?${NC}"; budget_label="unknown" ;;
    esac

    echo -e "${GREEN}✓ Report date:${NC}    ${S3_COST_REPORT_DATE} (${S3_COST_AGE_DAYS}d ago)"
    echo -e "${budget_icon} Total cost:${NC}     AUD \$$(printf '%.4f' "$S3_COST_TOTAL_AUD")/mo — ${budget_label} (budget: AUD \$${S3_COST_BUDGET_AUD_VAL})"
    echo -e "${GREEN}✓ Storage:${NC}        $(format_bytes "${S3_COST_TOTAL_BYTES}") (${S3_COST_TOTAL_OBJECTS} objects)"
    echo -e "${GREEN}✓ By service:${NC}     database=$(printf '%.4f' "$S3_COST_DATABASE_AUD")  foundry=$(printf '%.4f' "$S3_COST_FOUNDRY_AUD")  logs=$(printf '%.4f' "$S3_COST_LOGS_AUD")  configs=$(printf '%.4f' "$S3_COST_CONFIGS_AUD") (AUD/mo)"

    if [[ "$S3_COST_FRESHNESS" == "Stale" ]]; then
        echo -e "${YELLOW}⚠ Cost report is stale (${S3_COST_AGE_DAYS}d old; threshold ${S3_COST_STALE_DAYS}d).${NC}"
        echo -e "${YELLOW}  Run: backups/monitoring/costs/s3-cost-report.sh${NC}"
        return 1
    fi

    return 0
}
