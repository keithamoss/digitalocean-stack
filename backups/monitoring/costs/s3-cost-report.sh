#!/bin/bash
# S3 Cost Report — Phase 6A: Cost Baseline & Visibility
#
# Generates a per-service, per-storage-class cost breakdown for the
# jig-ho-cottage-dr S3 bucket using S3 list-objects-v2.
#
# The IAM backup user has s3:ListBucket + s3:GetObject access only, so
# this script works entirely from S3 object enumeration and applies
# published ap-southeast-2 pricing to calculate estimated monthly costs.
#
# AWS Cost Explorer (actual billing) requires an additional IAM permission
# (ce:GetCostAndUsage). See the "Optional: Actual Billing" section below
# for how to enable it when the IAM policy is updated.
#
# Usage:
#   ./s3-cost-report.sh [OPTIONS]
#
# Options:
#   --discord           Send summary report to Discord after generating
#   --no-save-state     Skip writing results to monitoring state file
#
# Output:
#   Console report + optional Discord embed
#   State file: backups/monitoring/state/s3-costs-YYYY-MM.json (default: written)
#
# Run monthly (or on-demand) to track cost trends over time.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
MONITORING_DIR="$(realpath "$SCRIPT_DIR/..")"
BACKUPS_DIR="$(realpath "$MONITORING_DIR/..")"
SECRETS_DIR="${BACKUPS_DIR}/secrets"
STATE_DIR="${MONITORING_DIR}/state"
# Monthly snapshot file — one per calendar month, accumulates for trend comparisons
THIS_MONTH=$(date '+%Y-%m')
STATE_FILE="${STATE_DIR}/s3-costs-${THIS_MONTH}.json"
# Legacy single-file path kept for check-s3-costs.sh compatibility (symlink updated after write)
STATE_LATEST="${STATE_DIR}/s3-costs-latest.json"
DISCORD_LIB="${MONITORING_DIR}/scripts/discord-lib.sh"

# ─── Parse Arguments ────────────────────────────────────────────────────────

SEND_DISCORD=false
SAVE_STATE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --discord)         SEND_DISCORD=true;   shift ;;
        --no-save-state)   SAVE_STATE=false;    shift ;;
        -h|--help)
            grep '^#' "$0" | head -30 | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ─── Load Config and Secrets ────────────────────────────────────────────────

source "${BACKUPS_DIR}/config.sh"
source "${SECRETS_DIR}/aws.env"
[[ -f "${SECRETS_DIR}/discord.env" ]] && source "${SECRETS_DIR}/discord.env"
source "$DISCORD_LIB"

mkdir -p "$STATE_DIR"

# ─── Constants ──────────────────────────────────────────────────────────────

readonly BUCKET="${S3_BUCKET_PREFIX}"
readonly REGION="${AWS_REGION}"
readonly REPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
readonly REPORT_EPOCH=$(date +%s)
readonly MAX_PAGES=200   # Safety limit: 200,000 objects per prefix

# S3 pricing from config.sh
readonly PRICE_STANDARD="${S3_PRICE_STANDARD}"
readonly PRICE_GIR="${S3_PRICE_GIR}"
readonly PRICE_GFR="${S3_PRICE_GFR}"
readonly PRICE_GDA="${S3_PRICE_GDA}"

readonly BUDGET_AUD="${S3_COST_BUDGET_AUD}"

# ─── Live FX Rate (USD → AUD) ────────────────────────────────────────────────
# Try open.er-api.com (no auth required, free tier). Falls back to the
# hardcoded config.sh constant if the request fails or times out.
_fetch_usd_to_aud() {
    local rate
    rate=$(curl -sf --max-time 8 \
        "https://open.er-api.com/v6/latest/USD" \
        | jq -r '.rates.AUD // empty' 2>/dev/null)
    if [[ -n "$rate" ]] && [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$rate"
        return 0
    fi
    return 1
}

FX_SOURCE="config.sh (fallback)"
if live_rate=$(_fetch_usd_to_aud 2>/dev/null); then
    USD_TO_AUD="$live_rate"
    FX_SOURCE="open.er-api.com (live)"
else
    USD_TO_AUD="${S3_COST_USD_TO_AUD}"
fi
readonly USD_TO_AUD FX_SOURCE

# Service prefix map (order matters for output)
readonly -a SERVICE_ORDER=(database foundry logs configs)
declare -A SERVICE_PREFIXES=(
    [database]="pi-hosting/database"
    [foundry]="pi-hosting/foundry"
    [logs]="pi-hosting/logs"
    [configs]="pi-hosting/configs"
)

# ─── Utility Functions ───────────────────────────────────────────────────────

hr() { printf '%.0s-' {1..72}; echo; }

format_bytes() {
    local bytes=${1:-0}
    [[ ! "$bytes" =~ ^[0-9]+$ ]] && bytes=0
    if ((bytes >= 1073741824)); then
        printf "%.2f GiB" "$(echo "scale=2; $bytes/1073741824" | bc)"
    elif ((bytes >= 1048576)); then
        printf "%.2f MiB" "$(echo "scale=2; $bytes/1048576" | bc)"
    elif ((bytes >= 1024)); then
        printf "%.2f KiB" "$(echo "scale=2; $bytes/1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

format_aud() {
    # Print with 4dp so very small amounts (configs) show as non-zero
    printf "AUD \$%.4f" "${1:-0}"
}

price_for_class() {
    case "$1" in
        STANDARD)       echo "$PRICE_STANDARD" ;;
        GLACIER_IR)     echo "$PRICE_GIR" ;;
        GLACIER)        echo "$PRICE_GFR" ;;
        DEEP_ARCHIVE)   echo "$PRICE_GDA" ;;
        STANDARD_IA)    echo "${S3_PRICE_STANDARD_IA}" ;;
        *)              echo "$PRICE_STANDARD" ;;  # conservative fallback
    esac
}

class_label() {
    case "$1" in
        STANDARD)    echo "S3 Standard" ;;
        GLACIER_IR)  echo "Glacier Instant Retrieval" ;;
        GLACIER)     echo "Glacier Flexible Retrieval" ;;
        DEEP_ARCHIVE) echo "Glacier Deep Archive" ;;
        STANDARD_IA) echo "Standard-IA" ;;
        *)           echo "$1" ;;
    esac
}

# calculate_cost_aud bytes price_per_gb_usd
# Returns AUD cost as decimal string
calculate_cost_aud() {
    local bytes="$1"
    local price_usd="$2"
    echo "scale=6; ($bytes / 1073741824) * $price_usd * $USD_TO_AUD" | bc
}

# ─── S3 Data Collection ──────────────────────────────────────────────────────

# enumerate_prefix
# Lists all objects under a prefix, returns JSON grouped by storage class.
# Output: [{"class":"STANDARD","bytes":12345,"objects":42}, ...]
enumerate_prefix() {
    local prefix="$1"
    local page=0
    local next_token=""
    local combined="[]"

    printf "  Scanning %-30s" "${prefix}/..." >&2

    while true; do
        ((page++))
        if ((page > MAX_PAGES)); then
            echo " WARNING: >200,000 objects (partial)" >&2
            break
        fi

        local args=(--bucket "$BUCKET" --prefix "${prefix}/" --output json)
        [[ -n "$next_token" ]] && args+=(--continuation-token "$next_token")

        local page_result
        if ! page_result=$(aws s3api list-objects-v2 "${args[@]}" 2>/dev/null); then
            echo " ERROR listing objects" >&2
            break
        fi

        # Accumulate items: [{class, bytes}]
        local page_items
        page_items=$(echo "$page_result" | \
            jq '[.Contents[]? | {class: (.StorageClass // "STANDARD"), bytes: .Size}]')
        combined=$(jq -n --argjson a "$combined" --argjson b "$page_items" '$a + $b')

        local is_truncated
        is_truncated=$(echo "$page_result" | jq -r '.IsTruncated // false')
        [[ "$is_truncated" != "true" ]] && break

        next_token=$(echo "$page_result" | jq -r '.NextContinuationToken // empty')
        [[ -z "$next_token" ]] && break
    done

    # Group by storage class, sum bytes & count objects
    local result
    result=$(jq -n --argjson data "$combined" '
        if ($data | length) == 0 then []
        else $data | group_by(.class) |
            map({
                class: .[0].class,
                bytes: (map(.bytes) | add // 0),
                objects: length
            }) | sort_by(-.bytes)
        end')

    local total_bytes total_objects
    total_bytes=$(echo "$result" | jq '[.[].bytes] | add // 0')
    total_objects=$(echo "$result" | jq '[.[].objects] | add // 0')
    printf " %s (%s objects)\n" "$(format_bytes "$total_bytes")" "$total_objects" >&2

    echo "$result"
}

# Optional: try Cost Explorer for actual billing data
# Requires ce:GetCostAndUsage IAM permission (not in current backup policy).
# Returns "UNAVAILABLE" if permission denied.
try_cost_explorer() {
    local months="${1:-2}"
    local start_date end_date
    start_date=$(date -d "-${months} months" +%Y-%m-01)
    end_date=$(date +%Y-%m-01)

    local result
    if result=$(aws ce get-cost-and-usage \
        --time-period "Start=${start_date},End=${end_date}" \
        --granularity MONTHLY \
        --metrics "UnblendedCost" "UsageQuantity" \
        --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Simple Storage Service"]}}' \
        --group-by 'Type=DIMENSION,Key=USAGE_TYPE' \
        --region us-east-1 \
        --output json 2>/dev/null); then
        echo "$result"
    else
        echo "UNAVAILABLE"
    fi
}

# ─── Load Historical Snapshots for Trend Comparison ────────────────────────

# Find the state file from ~1 month ago (last month's slug)
_prev_month_state() {
    local slug
    slug=$(date -d 'last month' '+%Y-%m' 2>/dev/null || date -v-1m '+%Y-%m' 2>/dev/null)
    echo "${STATE_DIR}/s3-costs-${slug}.json"
}

# Find the state file from ~12 months ago (same month last year)
_year_ago_state() {
    local slug
    slug=$(date -d '12 months ago' '+%Y-%m' 2>/dev/null)
    echo "${STATE_DIR}/s3-costs-${slug}.json"
}

# Read estimated_total_aud from a state file, return empty string if unavailable
_read_total_aud() {
    local file="$1"
    [[ -f "$file" ]] && jq -r '.estimated_total_aud // empty' "$file" 2>/dev/null || true
}

# Read estimated_cost_aud for a specific service from a state file
_read_svc_cost_aud() {
    local file="$1" svc="$2"
    [[ -f "$file" ]] && jq -r --arg svc "$svc" '.services[$svc].estimated_cost_aud // empty' "$file" 2>/dev/null || true
}

# Format a cost delta with sign and percentage
_format_delta() {
    local current="$1" previous="$2"
    if [[ -z "$previous" ]] || [[ "$previous" == "0" ]]; then
        echo "(no prior data)"
        return
    fi
    local delta pct sign
    delta=$(echo "scale=4; $current - $previous" | bc)
    pct=$(echo "scale=1; ($delta / $previous) * 100" | bc)
    if (( $(echo "$delta >= 0" | bc) )); then sign="+"; else sign=""; fi
    printf "%s%s AUD (%s%s%%)" "$sign" "$delta" "$sign" "$pct"
}

PREV_MONTH_FILE=$(_prev_month_state)
YEAR_AGO_FILE=$(_year_ago_state)
PREV_MONTH_TOTAL=$(_read_total_aud "$PREV_MONTH_FILE")
YEAR_AGO_TOTAL=$(_read_total_aud "$YEAR_AGO_FILE")
PREV_MONTH_LABEL=$(date -d 'last month' '+%B %Y' 2>/dev/null || echo 'last month')
YEAR_AGO_LABEL=$(date -d '12 months ago' '+%B %Y' 2>/dev/null || echo 'last year')

# Per-service historical costs (loaded after SERVICE_ORDER is defined above)
declare -A PREV_MONTH_SVC_COST
declare -A YEAR_AGO_SVC_COST

# ─── Main Report ─────────────────────────────────────────────────────────────

echo ""
echo "=== S3 Cost Report: ${BUCKET} (${REGION}) ==="
echo "Generated: ${REPORT_DATE}"
echo "Note: Costs are estimates based on object sizes × current pricing."
echo "      Actual billing may vary due to request charges and data transfer."
echo ""
echo "Scanning S3 prefixes (this may take 10-60s for large archives)..."
echo ""

# Collect per-service storage data
declare -A SVC_BREAKDOWN_JSON
declare -A SVC_TOTAL_BYTES
declare -A SVC_TOTAL_OBJECTS
declare -A SVC_COST_AUD

for svc in "${SERVICE_ORDER[@]}"; do
    prefix="${SERVICE_PREFIXES[$svc]}"
    breakdown=$(enumerate_prefix "$prefix")
    SVC_BREAKDOWN_JSON[$svc]="$breakdown"
    SVC_TOTAL_BYTES[$svc]=$(echo "$breakdown" | jq '[.[].bytes] | add // 0')
    SVC_TOTAL_OBJECTS[$svc]=$(echo "$breakdown" | jq '[.[].objects] | add // 0')

    # Calculate estimated cost from per-class pricing
    cost_aud=0
    while IFS=$'\t' read -r class bytes; do
        [[ -z "$class" || -z "$bytes" ]] && continue
        price=$(price_for_class "$class")
        c=$(echo "scale=6; ($bytes / 1073741824) * $price * $USD_TO_AUD" | bc)
        cost_aud=$(echo "scale=6; $cost_aud + $c" | bc)
    done < <(echo "${SVC_BREAKDOWN_JSON[$svc]}" | jq -r '.[] | [.class, (.bytes | tostring)] | @tsv')
    SVC_COST_AUD[$svc]="$cost_aud"
done

# Load per-service historical costs now that SVC_COST_AUD is populated
for svc in "${SERVICE_ORDER[@]}"; do
    PREV_MONTH_SVC_COST[$svc]=$(_read_svc_cost_aud "$PREV_MONTH_FILE" "$svc")
    YEAR_AGO_SVC_COST[$svc]=$(_read_svc_cost_aud "$YEAR_AGO_FILE" "$svc")
done

# Try Cost Explorer (likely unavailable with current IAM policy)
CE_RESULT=$(try_cost_explorer 2)
CE_AVAILABLE=false
[[ "$CE_RESULT" != "UNAVAILABLE" ]] && CE_AVAILABLE=true

# Aggregate totals
TOTAL_BYTES=0
TOTAL_COST_AUD=0
TOTAL_OBJECTS=0
for svc in "${SERVICE_ORDER[@]}"; do
    TOTAL_BYTES=$((TOTAL_BYTES + SVC_TOTAL_BYTES[$svc]))
    TOTAL_COST_AUD=$(echo "scale=6; $TOTAL_COST_AUD + ${SVC_COST_AUD[$svc]}" | bc)
    TOTAL_OBJECTS=$((TOTAL_OBJECTS + SVC_TOTAL_OBJECTS[$svc]))
done

# Budget status
BUDGET_UNDER=$(echo "$TOTAL_COST_AUD < $BUDGET_AUD" | bc)
BUDGET_STATUS="under"
if [[ "$BUDGET_UNDER" == "0" ]]; then
    BUDGET_NEAR=$(echo "$TOTAL_COST_AUD >= ($BUDGET_AUD * 0.8)" | bc)
    BUDGET_STATUS="over"
    [[ "$BUDGET_NEAR" == "1" && "$BUDGET_UNDER" == "0" ]] && BUDGET_STATUS="near"
else
    BUDGET_NEAR=$(echo "$TOTAL_COST_AUD >= ($BUDGET_AUD * 0.8)" | bc)
    [[ "$BUDGET_NEAR" == "1" ]] && BUDGET_STATUS="near"
fi

# Build ranked cost drivers (top entries across all services × classes)
DRIVERS_JSON="[]"
for svc in "${SERVICE_ORDER[@]}"; do
    while IFS=$'\t' read -r class bytes objects; do
        [[ -z "$class" ]] && continue
        price=$(price_for_class "$class")
        c=$(echo "scale=6; ($bytes / 1073741824) * $price * $USD_TO_AUD" | bc)
        entry=$(jq -n \
            --arg svc "$svc" \
            --arg class "$class" \
            --argjson bytes "$bytes" \
            --argjson objects "$objects" \
            --arg cost_aud "$c" \
            '{service: $svc, class: $class, bytes: $bytes, objects: $objects, cost_aud: ($cost_aud | tonumber)}')
        DRIVERS_JSON=$(jq -n \
            --argjson arr "$DRIVERS_JSON" \
            --argjson e "$entry" \
            '$arr + [$e] | sort_by(-.cost_aud)')
    done < <(echo "${SVC_BREAKDOWN_JSON[$svc]}" | \
        jq -r '.[] | [.class, (.bytes | tostring), (.objects | tostring)] | @tsv')
done

# ─── Console Report ───────────────────────────────────────────────────────────

echo ""
hr

# Section 1: Storage by Service
printf "\n%-10s  %12s  %10s  %14s\n" "SERVICE" "SIZE" "OBJECTS" "EST COST/MONTH"
printf "%-10s  %12s  %10s  %14s\n" "-------" "----" "-------" "--------------"

for svc in "${SERVICE_ORDER[@]}"; do
    bytes="${SVC_TOTAL_BYTES[$svc]}"
    objects="${SVC_TOTAL_OBJECTS[$svc]}"
    cost_aud="${SVC_COST_AUD[$svc]}"
    printf "%-10s  %12s  %10s  %14s\n" \
        "$svc" \
        "$(format_bytes "$bytes")" \
        "$objects" \
        "$(format_aud "$cost_aud")"
done

printf "\n%-10s  %12s  %10s  %14s\n" \
    "TOTAL" \
    "$(format_bytes "$TOTAL_BYTES")" \
    "$TOTAL_OBJECTS" \
    "$(format_aud "$TOTAL_COST_AUD")"

hr

# Section 2: Storage class breakdown per service
echo ""
echo "Storage Class Breakdown:"
echo ""
for svc in "${SERVICE_ORDER[@]}"; do
    breakdown="${SVC_BREAKDOWN_JSON[$svc]}"
    entry_count=$(echo "$breakdown" | jq 'length')
    if ((entry_count == 0)); then
        printf "  %-10s  (empty)\n" "$svc"
        continue
    fi
    printf "  %-10s\n" "$svc"
    while IFS=$'\t' read -r class bytes objects; do
        [[ -z "$class" ]] && continue
        price=$(price_for_class "$class")
        c=$(echo "scale=4; ($bytes / 1073741824) * $price * $USD_TO_AUD" | bc)
        printf "    %-32s  %10s  (%s objects)  → %s/mo\n" \
            "$(class_label "$class")" \
            "$(format_bytes "$bytes")" \
            "$objects" \
            "$(format_aud "$c")"
    done < <(echo "$breakdown" | jq -r '.[] | [.class, (.bytes | tostring), (.objects | tostring)] | @tsv')
done

hr

# Section 3: Ranked cost drivers
echo ""
echo "Top Cost Drivers (ranked by estimated monthly cost):"
echo ""
rank=1
while IFS=$'\t' read -r svc class cost_aud bytes objects; do
    [[ -z "$svc" ]] && continue
    printf "  %2d. %-10s %-34s  %s/mo  (%s)\n" \
        "$rank" \
        "$svc" \
        "$(class_label "$class")" \
        "$(format_aud "$cost_aud")" \
        "$(format_bytes "$bytes")"
    ((rank++))
done < <(echo "$DRIVERS_JSON" | jq -r '.[] | [.service, .class, (.cost_aud | tostring), (.bytes | tostring), (.objects | tostring)] | @tsv')

hr

# Section 4: Budget + trend
echo ""
BUDGET_REMAINING=$(echo "scale=4; $BUDGET_AUD - $TOTAL_COST_AUD" | bc)
case "$BUDGET_STATUS" in
    under) echo "  Budget Status:  ✅  $(format_aud "$TOTAL_COST_AUD") / month  (budget: $(format_aud "$BUDGET_AUD") — $(format_aud "$BUDGET_REMAINING") remaining)" ;;
    near)  echo "  Budget Status:  ⚠   $(format_aud "$TOTAL_COST_AUD") / month  (budget: $(format_aud "$BUDGET_AUD") — approaching limit)" ;;
    over)  echo "  Budget Status:  ❌  $(format_aud "$TOTAL_COST_AUD") / month  (exceeds budget of $(format_aud "$BUDGET_AUD"))" ;;
esac
echo ""
echo "  Trend vs ${PREV_MONTH_LABEL}:   $(_format_delta "$TOTAL_COST_AUD" "$PREV_MONTH_TOTAL")"
echo "  Trend vs ${YEAR_AGO_LABEL}:  $(_format_delta "$TOTAL_COST_AUD" "$YEAR_AGO_TOTAL")"
echo ""
echo "  Per-Service vs ${PREV_MONTH_LABEL} / ${YEAR_AGO_LABEL}:"
for svc in "${SERVICE_ORDER[@]}"; do
    mom=$(_format_delta "${SVC_COST_AUD[$svc]}" "${PREV_MONTH_SVC_COST[$svc]}")
    yoy=$(_format_delta "${SVC_COST_AUD[$svc]}" "${YEAR_AGO_SVC_COST[$svc]}")
    printf "    %-10s  MoM: %-30s  YoY: %s\n" "${svc}:" "$mom" "$yoy"
done

# Section 5: FX rate used
echo ""
echo "  FX Rate:        1 USD = ${USD_TO_AUD} AUD  (source: ${FX_SOURCE})"

# Section 6: Cost Explorer status
echo ""
if $CE_AVAILABLE; then
    echo "  Cost Explorer:  ✅  Actual billing data available (see below)"
else
    echo "  Cost Explorer:  ℹ   Not available with current IAM policy."
    echo "                      To enable: add ce:GetCostAndUsage to the IAM user policy."
    echo "                      See S3_SETUP.md → 'Optional: Cost Explorer' for instructions."
fi

hr
echo ""

# ─── Optional: Discord Summary ────────────────────────────────────────────────

if $SEND_DISCORD; then
    # Colour based on budget status
    local_color=5763719  # green
    [[ "$BUDGET_STATUS" == "near" ]] && local_color=16776960
    [[ "$BUDGET_STATUS" == "over" ]] && local_color=15548997

    local_emoji="✅"
    [[ "$BUDGET_STATUS" == "near" ]] && local_emoji="⚠️"
    [[ "$BUDGET_STATUS" == "over" ]] && local_emoji="🚨"

    # ── By-Service table (monospace code block for alignment) ──────────────
    # Columns: Service | Size | Cost/mo | MoM | YoY
    svc_table="Service     Size        Cost/mo      MoM             YoY\n"
    svc_table+="────────────────────────────────────────────────────────────────\n"
    for svc in "${SERVICE_ORDER[@]}"; do
        mom=$(_format_delta "${SVC_COST_AUD[$svc]}" "${PREV_MONTH_SVC_COST[$svc]}")
        yoy=$(_format_delta "${SVC_COST_AUD[$svc]}" "${YEAR_AGO_SVC_COST[$svc]}")
        svc_table+=$(printf "%-10s  %-10s  %-11s  %-14s  %s" \
            "$svc" \
            "$(format_bytes "${SVC_TOTAL_BYTES[$svc]}")" \
            "$(format_aud "${SVC_COST_AUD[$svc]}")" \
            "$mom" \
            "$yoy")
        svc_table+="\n"
    done
    svc_table+="────────────────────────────────────────────────────────────────\n"
    mom_total=$(_format_delta "$TOTAL_COST_AUD" "$PREV_MONTH_TOTAL")
    yoy_total=$(_format_delta "$TOTAL_COST_AUD" "$YEAR_AGO_TOTAL")
    svc_table+=$(printf "%-10s  %-10s  %-11s  %-14s  %s" \
        "TOTAL" \
        "$(format_bytes "$TOTAL_BYTES")" \
        "$(format_aud "$TOTAL_COST_AUD")" \
        "$mom_total" \
        "$yoy_total")
    svc_table+="\n"

    # Budget status line
    budget_icon="✅"; [[ "$BUDGET_STATUS" == "near" ]] && budget_icon="⚠️"; [[ "$BUDGET_STATUS" == "over" ]] && budget_icon="🚨"
    budget_line="${budget_icon} $(format_aud "$TOTAL_COST_AUD")/mo"
    [[ "$BUDGET_STATUS" == "under" ]] && budget_line+=" — $(format_aud "$BUDGET_REMAINING") under $(format_aud "$BUDGET_AUD") budget"
    [[ "$BUDGET_STATUS" == "near"  ]] && budget_line+=" — approaching $(format_aud "$BUDGET_AUD") budget"
    [[ "$BUDGET_STATUS" == "over"  ]] && budget_line+=" — OVER $(format_aud "$BUDGET_AUD") budget 🚨"

    # Top 3 drivers (plain text, concise)
    top3=""
    rank=1
    while IFS=$'\t' read -r svc class cost_aud bytes _; do
        [[ -z "$svc" || $rank -gt 3 ]] && break
        top3+="${rank}. **${svc}** $(class_label "$class"): $(format_aud "$cost_aud")/mo ($(format_bytes "$bytes"))\n"
        ((rank++))
    done < <(echo "$DRIVERS_JSON" | jq -r '.[] | [.service, .class, (.cost_aud | tostring), (.bytes | tostring), (.objects | tostring)] | @tsv')

    desc="**Bucket:** \`${BUCKET}\` (${REGION}) — ${budget_line}\n\n"
    desc+="\`\`\`\n${svc_table}\`\`\`\n"
    desc+="**Top Cost Drivers:**\n${top3}"
    desc+="\n_FX: 1 USD = ${USD_TO_AUD} AUD (${FX_SOURCE})_"
    [[ "$CE_AVAILABLE" == "false" ]] && desc+=" _| Enable Cost Explorer for actual billing_"

    send_discord "S3 Cost Report" "$desc" "$local_color" "💰"
fi

# ─── Write State File ─────────────────────────────────────────────────────────

if $SAVE_STATE; then
    # Emit null for Cost Explorer if unavailable
    ce_json="null"
    $CE_AVAILABLE && ce_json="$CE_RESULT"

    # Build per-service JSON object
    services_json="{}"
    for svc in "${SERVICE_ORDER[@]}"; do
        svc_entry=$(jq -n \
            --argjson size "${SVC_TOTAL_BYTES[$svc]}" \
            --argjson objects "${SVC_TOTAL_OBJECTS[$svc]}" \
            --arg cost_aud "${SVC_COST_AUD[$svc]}" \
            --argjson breakdown "${SVC_BREAKDOWN_JSON[$svc]}" \
            '{
                size_bytes: $size,
                objects: $objects,
                estimated_cost_aud: ($cost_aud | tonumber),
                storage_breakdown: $breakdown
            }')
        services_json=$(jq -n \
            --argjson base "$services_json" \
            --arg k "$svc" \
            --argjson v "$svc_entry" \
            '$base + {($k): $v}')
    done

    # Total objects tracked in aggregation loop
    total_objects="$TOTAL_OBJECTS"

    jq -n \
        --arg report_date "$REPORT_DATE" \
        --argjson report_epoch "$REPORT_EPOCH" \
        --arg bucket "$BUCKET" \
        --arg region "$REGION" \
        --argjson budget_aud "$BUDGET_AUD" \
        --arg total_cost_aud "$TOTAL_COST_AUD" \
        --argjson total_bytes "$TOTAL_BYTES" \
        --argjson total_objects "$total_objects" \
        --arg budget_status "$BUDGET_STATUS" \
        --arg usd_to_aud "$USD_TO_AUD" \
        --arg fx_source "$FX_SOURCE" \
        --argjson services "$services_json" \
        --argjson top_cost_drivers "$DRIVERS_JSON" \
        --argjson cost_explorer_available "$CE_AVAILABLE" \
        --argjson actual_billing "$ce_json" \
        --arg prev_month_label "$PREV_MONTH_LABEL" \
        --arg prev_month_total "${PREV_MONTH_TOTAL:-}" \
        --arg year_ago_label "$YEAR_AGO_LABEL" \
        --arg year_ago_total "${YEAR_AGO_TOTAL:-}" \
        '{
            report_date: $report_date,
            report_epoch: $report_epoch,
            bucket: $bucket,
            region: $region,
            budget_aud: $budget_aud,
            estimated_total_aud: ($total_cost_aud | tonumber),
            total_size_bytes: $total_bytes,
            total_objects: $total_objects,
            budget_status: $budget_status,
            usd_to_aud: ($usd_to_aud | tonumber),
            fx_source: $fx_source,
            trend: {
                prev_month_label: $prev_month_label,
                prev_month_total_aud: (if $prev_month_total != "" then ($prev_month_total | tonumber) else null end),
                year_ago_label: $year_ago_label,
                year_ago_total_aud: (if $year_ago_total != "" then ($year_ago_total | tonumber) else null end)
            },
            services: $services,
            top_cost_drivers: $top_cost_drivers,
            cost_explorer_available: $cost_explorer_available,
            actual_billing: $actual_billing
        }' > "$STATE_FILE"

    # Update the stable symlink so check-s3-costs.sh always finds the latest
    if [[ -f "$STATE_FILE" ]]; then
        echo "Note: Updating existing ${THIS_MONTH} state file (use --no-save-state to skip)"
    fi
    ln -sf "$(basename "$STATE_FILE")" "$STATE_LATEST"

    echo "State written to: ${STATE_FILE} (symlinked from $(basename "$STATE_LATEST"))"
fi

echo "Report complete."
