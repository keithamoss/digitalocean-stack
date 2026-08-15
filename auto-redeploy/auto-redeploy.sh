#!/bin/bash
# auto-redeploy.sh — polls GitHub Actions and deploys on successful builds
#
# Installed at /usr/local/bin/auto-redeploy.sh by auto-redeploy/install.sh.
# STACK_DIR is substituted at install time (same pattern as backups/install-systemd.sh).
STACK_DIR="@STACK_DIR@"

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────

LOG_FILE="${STACK_DIR}/logs/auto-redeploy/auto-redeploy.log"
ENABLED_DIR="${STACK_DIR}/auto-redeploy/enabled"
STATE_DIR="${STACK_DIR}/auto-redeploy/state"
DISCORD_LIB="${STACK_DIR}/backups/monitoring/scripts/discord-lib.sh"
GITHUB_ENV="${STACK_DIR}/auto-redeploy/secrets/github.env"
DISCORD_ENV="${STACK_DIR}/auto-redeploy/secrets/discord.env"

DRY_RUN="${DRY_RUN:-false}"
CURRENT_TARGET="system"

# ── Logging ───────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${CURRENT_TARGET}] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

# ── Notifications ─────────────────────────────────────────────────────────────

if [ -f "$DISCORD_LIB" ]; then
    # shellcheck source=/dev/null
    source "$DISCORD_LIB"
fi
if [ -f "$DISCORD_ENV" ]; then
    # shellcheck source=/dev/null
    source "$DISCORD_ENV"
fi
if [ -f "$GITHUB_ENV" ]; then
    # shellcheck source=/dev/null
    source "$GITHUB_ENV"
fi

notify_success() {
    local target="$1" run_id="$2" sha="$3"
    if declare -f send_discord &>/dev/null; then
        send_discord \
            "[${target}] Deployed run ${run_id} (SHA: ${sha:0:8})" \
            "Deployment completed successfully." \
            5763719 "✅" || true
    else
        log "Discord not configured — skipping success notification"
    fi
}

notify_failure() {
    local target="$1" msg="$2"
    if declare -f send_discord &>/dev/null; then
        send_discord \
            "[${target}] ${msg}" \
            "Check \`logs/auto-redeploy/auto-redeploy.log\` for details." \
            15548997 "❌" || true
    else
        log "Discord not configured — skipping failure notification"
    fi
}

# ── State management ──────────────────────────────────────────────────────────

read_state() {
    local state_file="$1"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo '{}'
    fi
}

get_state_field() {
    local state_file="$1" field="$2" default="${3:-null}"
    read_state "$state_file" | jq -r --arg d "$default" ".${field} // \$d"
}

update_state() {
    local state_file="$1" updates="$2"
    mkdir -p "$(dirname "$state_file")"
    local current updated
    current=$(read_state "$state_file")
    if ! updated=$(printf '%s' "$current" | jq --argjson u "$updates" '. + $u' 2>/dev/null); then
        # Fallback: if existing state is corrupt, start fresh with just the updates
        updated=$(printf '%s' "$updates" | jq '.')
    fi
    printf '%s\n' "$updated" > "$state_file"
}

# ── GitHub API ────────────────────────────────────────────────────────────────

github_api_call() {
    local url="$1"
    local args=(-sSL -w "\nHTTP_STATUS:%{http_code}" --max-time 30)
    args+=(-H "Accept: application/vnd.github+json")
    args+=(-H "X-GitHub-Api-Version: 2022-11-28")
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    curl "${args[@]}" "$url"
}

# Prints body on success; returns 1 on HTTP error
parse_api_response() {
    local response="$1"
    local http_status body
    http_status=$(printf '%s' "$response" | awk -F: '/^HTTP_STATUS:/{print $2}' | tail -n1)
    body=$(printf '%s' "$response" | sed '/^HTTP_STATUS:/d')
    if [ -z "$http_status" ] || [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
        return 1
    fi
    printf '%s' "$body"
}

fetch_latest_run() {
    local repo="$1" workflow="$2" branch="$3" per_page="${4:-20}"
    local url="https://api.github.com/repos/${repo}/actions/workflows/${workflow}/runs?branch=${branch}&per_page=${per_page}"
    local response body
    response=$(github_api_call "$url") || return 1
    body=$(parse_api_response "$response") || return 1
    printf '%s' "$body"
}

select_candidate_run() {
    local runs_json="$1" last_seen_run_id="$2" last_seen_run_number="$3" last_seen_run_attempt="$4" last_seen_created_at="$5"
    # Choose from a bounded recent window to catch reruns that are not the single
    # most recent run while keeping API and processing cost predictable.
    printf '%s' "$runs_json" | jq \
        --argjson last_id "$last_seen_run_id" \
        --argjson last_number "$last_seen_run_number" \
        --argjson last_attempt "$last_seen_run_attempt" \
        --arg last_created "$last_seen_created_at" '
        def ordered:
            (.workflow_runs // [])
            | sort_by((.run_number // 0), (.created_at // ""), (.id // 0))
            | reverse
            | .[:12];

        def actionable($last_id; $last_number; $last_attempt; $last_created):
            select(
                ((.run_number // 0) > $last_number)
                or (((.run_number // 0) == $last_number) and ((.created_at // "") > $last_created))
                or (((.id // 0) == $last_id) and ((.run_attempt // 1) > $last_attempt))
            );

        (ordered | map(actionable($last_id; $last_number; $last_attempt; $last_created)) | .[0])
        // (ordered | .[0])
        // empty
    '
}

fetch_run_by_id() {
    local repo="$1" run_id="$2"
    local url="https://api.github.com/repos/${repo}/actions/runs/${run_id}"
    local response
    response=$(github_api_call "$url") || return 1
    parse_api_response "$response" || return 1
}

# ── Deployment ────────────────────────────────────────────────────────────────

deploy() {
    local target="$1" run_id="$2" sha="$3" compose_file="$4"
    local cloudflare_purge="${5:-false}" cloudflare_env="${6:-}" refresh_nginx="${7:-true}"
    local nginx_script="${STACK_DIR}/orchestration/nginx.sh"

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY RUN] Would run: docker compose -f ${compose_file} pull"
        log "[DRY RUN] Would run: docker compose -f ${compose_file} stop"
        log "[DRY RUN] Would run: docker compose -f ${compose_file} up --remove-orphans --wait --wait-timeout 60 -d"
        if [ "$refresh_nginx" = "true" ]; then
            log "[DRY RUN] Would run: ${nginx_script} --skip-download"
        else
            log "[DRY RUN] Would skip nginx refresh (REFRESH_NGINX=false)"
        fi
        log "[DRY RUN] Would run: docker image prune --force"
        if [ "$cloudflare_purge" = "true" ]; then
            if [ -n "$cloudflare_env" ]; then
                log "[DRY RUN] Would purge Cloudflare cache using ${cloudflare_env}"
            else
                log "[DRY RUN] Would fail: CLOUDFLARE_PURGE=true but CLOUDFLARE_ENV is not set"
            fi
        fi
        log "[DRY RUN] Deployment skipped (DRY_RUN=true)"
        return 0
    fi

    # Step 1: Pull new images (must succeed before stopping containers)
    log "Step 1/6: Pulling images..."
    if ! docker compose -f "$compose_file" pull; then
        log "ERROR: docker compose pull failed"
        return 1
    fi

    # Step 2: Stop containers
    log "Step 2/6: Stopping containers..."
    if ! docker compose -f "$compose_file" stop; then
        log "ERROR: docker compose stop failed"
        return 1
    fi

    # Step 3: Start updated containers
    log "Step 3/6: Starting updated containers..."
    if ! docker compose -f "$compose_file" up --remove-orphans --wait --wait-timeout 60 -d; then
        log "ERROR: docker compose up failed"
        return 1
    fi

    # Check for containers stuck in restarting state (brief wait to let crash-loops surface)
    sleep 5
    local restarting
    restarting=$(docker compose -f "$compose_file" ps 2>/dev/null | tail -n +2 | grep -i "restarting" | awk '{print $1}' || true)
    if [ -n "$restarting" ]; then
        log "ERROR: Containers in restarting state after up:"
        while IFS= read -r line; do log "  - $line"; done <<< "$restarting"
        return 1
    fi

    # Step 4: Refresh nginx to pick up current upstream mappings (optional per target)
    if [ "$refresh_nginx" = "true" ]; then
        log "Step 4/6: Refreshing nginx to pick up current upstream mappings..."
        if [ ! -x "$nginx_script" ]; then
            log "ERROR: nginx orchestration script not found or not executable: ${nginx_script}"
            return 1
        fi
        if ! "$nginx_script" --skip-download; then
            log "ERROR: nginx refresh failed via ${nginx_script}"
            return 1
        fi
    else
        log "Step 4/6: Nginx refresh disabled for this target (REFRESH_NGINX=false)"
    fi

    # Step 5: Prune old images (non-fatal)
    log "Step 5/6: Pruning old images..."
    docker image prune --force || true

    # Step 6: Cloudflare cache purge (optional but strict when enabled)
    if [ "$cloudflare_purge" = "true" ]; then
        log "Step 6/6: Purging Cloudflare cache..."
        if [ -z "$cloudflare_env" ]; then
            log "ERROR: CLOUDFLARE_PURGE=true but CLOUDFLARE_ENV is not set"
            return 1
        fi
        if [ ! -f "$cloudflare_env" ]; then
            log "ERROR: Cloudflare env not found: ${cloudflare_env}"
            return 1
        fi

        # shellcheck source=/dev/null
        source "$cloudflare_env"
        if [ -z "${CF_ZONE_ID:-}" ] || [ -z "${CF_EMAIL:-}" ] || [ -z "${CF_API_KEY:-}" ]; then
            log "ERROR: CF_ZONE_ID, CF_EMAIL, or CF_API_KEY not set"
            return 1
        fi

        local http_status
        http_status=$(curl -sS -o /dev/null -w "%{http_code}" \
            -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
            -H "X-Auth-Email: ${CF_EMAIL}" \
            -H "X-Auth-Key: ${CF_API_KEY}" \
            -H "Content-Type: application/json" \
            --data '{"purge_everything":true}')
        if [ "$http_status" = "200" ]; then
            log "Cloudflare cache purged (HTTP 200)"
        else
            log "ERROR: Cloudflare purge returned HTTP ${http_status}"
            return 1
        fi
    else
        log "Step 6/6: Cloudflare purge not configured — skipping"
    fi

    return 0
}

# ── Per-target processing ─────────────────────────────────────────────────────

process_target() {
    local conf_file="$1" target="$2"
    CURRENT_TARGET="$target"
    local state_file="${STATE_DIR}/${target}.json"

    log "Checking GitHub Actions..."

    # Unset config vars before sourcing to prevent leakage from previous target
    unset GITHUB_REPO WORKFLOW_FILE BRANCH COMPOSE_FILE CLOUDFLARE_PURGE CLOUDFLARE_ENV WATCH_TIMEOUT_MINS REFRESH_NGINX
    # shellcheck source=/dev/null
    source "$conf_file"

    # Validate required fields
    local missing=()
    for var in GITHUB_REPO WORKFLOW_FILE BRANCH COMPOSE_FILE; do
        [ -z "${!var:-}" ] && missing+=("$var")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        log "ERROR: Missing required config fields: ${missing[*]}"
        return 1
    fi

    local cloudflare_purge="${CLOUDFLARE_PURGE:-false}"
    local cloudflare_env="${CLOUDFLARE_ENV:-}"
    local watch_timeout_mins="${WATCH_TIMEOUT_MINS:-15}"
    local refresh_nginx="${REFRESH_NGINX:-true}"

    # Read current state
    local last_seen_run_id last_seen_run_number last_seen_run_attempt last_seen_created_at last_seen_head_sha
    local deployed_run_id deployed_run_attempt stale_response_count last_stale_alert_at
    local consecutive_api_failures last_api_alert_at
    last_seen_run_id=$(get_state_field "$state_file" "last_seen_run_id" "0")
    last_seen_run_number=$(get_state_field "$state_file" "last_seen_run_number" "0")
    last_seen_run_attempt=$(get_state_field "$state_file" "last_seen_run_attempt" "0")
    last_seen_created_at=$(get_state_field "$state_file" "last_seen_created_at" "")
    last_seen_head_sha=$(get_state_field "$state_file" "last_seen_head_sha" "")
    deployed_run_id=$(get_state_field "$state_file" "deployed_run_id" "0")
    deployed_run_attempt=$(get_state_field "$state_file" "deployed_run_attempt" "0")
    stale_response_count=$(get_state_field "$state_file" "stale_response_count" "0")
    last_stale_alert_at=$(get_state_field "$state_file" "last_stale_alert_at" "null")
    consecutive_api_failures=$(get_state_field "$state_file" "consecutive_api_failures" "0")
    last_api_alert_at=$(get_state_field "$state_file" "last_api_alert_at" "null")

    # Backward compatibility: old state files may not have last_seen_run_attempt.
    # Treat that as attempt 1 when a last_seen_run_id exists to avoid false rerun detection.
    if [ "$last_seen_run_id" != "0" ] && [ "$last_seen_run_attempt" = "0" ]; then
        last_seen_run_attempt="1"
        if [ "$DRY_RUN" != "true" ]; then
            update_state "$state_file" '{"last_seen_run_attempt": 1}'
        else
            log "[DRY RUN] Would migrate state: last_seen_run_attempt=1"
        fi
    fi

    # Backward compatibility: old state files may not have deployed_run_attempt.
    # If we have a deployed_run_id and the latest seen run matches it, assume that
    # attempt was the deployed one so reruns can redeploy once each going forward.
    if [ "$deployed_run_id" != "0" ] && [ "$deployed_run_attempt" = "0" ] && [ "$deployed_run_id" = "$last_seen_run_id" ] && [ "$last_seen_run_attempt" != "0" ]; then
        deployed_run_attempt="$last_seen_run_attempt"
        if [ "$DRY_RUN" != "true" ]; then
            update_state "$state_file" "{\"deployed_run_attempt\": ${last_seen_run_attempt}}"
        else
            log "[DRY RUN] Would migrate state: deployed_run_attempt=${last_seen_run_attempt}"
        fi
    fi

    # Poll GitHub Actions API
    local runs_json run_json
    if ! runs_json=$(fetch_latest_run "$GITHUB_REPO" "$WORKFLOW_FILE" "$BRANCH" "12"); then
        consecutive_api_failures=$((consecutive_api_failures + 1))
        log "GitHub API failure #${consecutive_api_failures} for ${GITHUB_REPO}/${WORKFLOW_FILE}@${BRANCH}"

        local should_alert=false
        if [ "$consecutive_api_failures" -eq 5 ]; then
            should_alert=true
        elif [ "$consecutive_api_failures" -gt 5 ] && [ "$last_api_alert_at" != "null" ]; then
            local now_epoch last_alert_epoch
            now_epoch=$(date +%s)
            last_alert_epoch=$(date -d "$last_api_alert_at" +%s 2>/dev/null || echo 0)
            [ $((now_epoch - last_alert_epoch)) -ge 3600 ] && should_alert=true
        fi

        if [ "$should_alert" = "true" ]; then
            notify_failure "$target" "GitHub API unreachable for ~${consecutive_api_failures} poll cycles — check connectivity or GitHub status"
            last_api_alert_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        fi

        # Write alert_at as JSON null or a quoted string
        local alert_at_json
        if [ "$last_api_alert_at" = "null" ]; then
            alert_at_json="null"
        else
            alert_at_json="\"${last_api_alert_at}\""
        fi
        if [ "$DRY_RUN" != "true" ]; then
            update_state "$state_file" \
                "{\"consecutive_api_failures\": ${consecutive_api_failures}, \"last_api_alert_at\": ${alert_at_json}}"
        else
            log "[DRY RUN] Would update state: consecutive_api_failures=${consecutive_api_failures}"
        fi
        return 0
    fi

    if ! run_json=$(select_candidate_run "$runs_json" "$last_seen_run_id" "$last_seen_run_number" "$last_seen_run_attempt" "$last_seen_created_at"); then
        log "ERROR: Failed to parse workflow run list from GitHub API"
        return 1
    fi

    # Reset API failure counter on success (only write if there were failures)
    if [ "${consecutive_api_failures}" != "0" ]; then
        log "GitHub API recovered after ${consecutive_api_failures} failure(s)"
        if [ "$DRY_RUN" != "true" ]; then
            update_state "$state_file" '{"consecutive_api_failures": 0, "last_api_alert_at": null}'
        fi
    fi

    if [ -z "$run_json" ]; then
        log "No workflow runs found for ${WORKFLOW_FILE} on branch ${BRANCH} — skipping"
        return 0
    fi

    local run_id run_status run_conclusion run_sha run_number run_attempt run_created_at
    run_id=$(printf '%s' "$run_json" | jq -r '.id')
    run_status=$(printf '%s' "$run_json" | jq -r '.status')
    run_conclusion=$(printf '%s' "$run_json" | jq -r '.conclusion // "null"')
    run_sha=$(printf '%s' "$run_json" | jq -r '.head_sha')
    run_number=$(printf '%s' "$run_json" | jq -r '.run_number // 0')
    run_attempt=$(printf '%s' "$run_json" | jq -r '.run_attempt // 1')
    run_created_at=$(printf '%s' "$run_json" | jq -r '.created_at // ""')

    # Validate run_id is a plain integer to prevent JSON injection in update_state calls
    if ! [[ "$run_id" =~ ^[0-9]+$ ]]; then
        log "ERROR: Unexpected run_id format from API: '${run_id}'"
        return 1
    fi
    if ! [[ "$run_number" =~ ^[0-9]+$ ]]; then
        log "ERROR: Unexpected run_number format from API: '${run_number}'"
        return 1
    fi
    if ! [[ "$run_attempt" =~ ^[0-9]+$ ]]; then
        log "ERROR: Unexpected run_attempt format from API: '${run_attempt}'"
        return 1
    fi

    # Idempotency: skip if already processed
    if [ "$run_id" = "$last_seen_run_id" ]; then
        if [ "$run_attempt" -le "$last_seen_run_attempt" ]; then
            log "Run ${run_id} attempt ${run_attempt} already processed — skipping"
            if [ "$stale_response_count" != "0" ] && [ "$DRY_RUN" != "true" ]; then
                update_state "$state_file" '{"stale_response_count": 0, "last_stale_alert_at": null}'
            fi
            return 0
        fi
        log "Run ${run_id} re-run detected (attempt ${run_attempt} > ${last_seen_run_attempt}) — re-processing"
    fi

    # Monotonic guard: reject stale/out-of-order responses to avoid run-id flip loops.
    local is_newer=false
    local is_rerun_attempt=false
    if [ "$run_id" = "$last_seen_run_id" ] && [ "$run_attempt" -gt "$last_seen_run_attempt" ]; then
        is_rerun_attempt=true
    fi

    if [ "$run_number" -gt "$last_seen_run_number" ]; then
        is_newer=true
    elif [ "$run_number" -eq "$last_seen_run_number" ] && [[ "$run_created_at" > "$last_seen_created_at" ]]; then
        is_newer=true
    elif [ "$is_rerun_attempt" = "true" ]; then
        is_newer=true
    fi

    if [ "$is_newer" != "true" ]; then
        stale_response_count=$((stale_response_count + 1))
        log "WARNING: Ignoring stale latest-run candidate (run_id=${run_id}, run_number=${run_number}, run_attempt=${run_attempt}, created_at=${run_created_at}); last_seen_run_id=${last_seen_run_id}, last_seen_run_number=${last_seen_run_number}, last_seen_run_attempt=${last_seen_run_attempt}, last_seen_created_at=${last_seen_created_at}"

        local stale_should_alert=false
        if [ "$stale_response_count" -ge 3 ]; then
            if [ "$last_stale_alert_at" = "null" ]; then
                stale_should_alert=true
            else
                local now_epoch stale_alert_epoch
                now_epoch=$(date +%s)
                stale_alert_epoch=$(date -d "$last_stale_alert_at" +%s 2>/dev/null || echo 0)
                [ $((now_epoch - stale_alert_epoch)) -ge 3600 ] && stale_should_alert=true
            fi
        fi

        if [ "$stale_should_alert" = "true" ]; then
            notify_failure "$target" "Detected stale/out-of-order workflow run responses (${stale_response_count} consecutive) — auto-redeploy ignored them safely"
            last_stale_alert_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        fi

        local stale_alert_at_json
        if [ "$last_stale_alert_at" = "null" ]; then
            stale_alert_at_json="null"
        else
            stale_alert_at_json="\"${last_stale_alert_at}\""
        fi

        if [ "$DRY_RUN" != "true" ]; then
            update_state "$state_file" "{\"stale_response_count\": ${stale_response_count}, \"last_stale_alert_at\": ${stale_alert_at_json}}"
        else
            log "[DRY RUN] Would update stale_response_count=${stale_response_count}"
        fi
        return 0
    fi

    if [ "$stale_response_count" != "0" ] && [ "$DRY_RUN" != "true" ]; then
        update_state "$state_file" '{"stale_response_count": 0, "last_stale_alert_at": null}'
    fi

    log "New run: ${run_id} (run_number=${run_number}, run_attempt=${run_attempt}, created_at=${run_created_at}, status=${run_status}, conclusion=${run_conclusion}, SHA=${run_sha:0:8})"

    # Enter watch loop if in-progress or queued
    if [ "$run_status" = "queued" ] || [ "$run_status" = "in_progress" ]; then
        local watch_timeout_secs=$(( watch_timeout_mins * 60 ))
        local watch_start elapsed_secs elapsed_mins elapsed_rem
        watch_start=$(date +%s)

        log "Run ${run_id} is ${run_status} — watching (15s interval, ${watch_timeout_mins}min timeout)"

        while true; do
            sleep 15

            elapsed_secs=$(( $(date +%s) - watch_start ))
            elapsed_mins=$(( elapsed_secs / 60 ))
            elapsed_rem=$(( elapsed_secs % 60 ))

            if [ "$elapsed_secs" -ge "$watch_timeout_secs" ]; then
                log "Watch timeout after ${elapsed_mins}m for run ${run_id} — skipping this cycle"
                notify_failure "$target" "Watch loop timed out after ${watch_timeout_mins}min for run ${run_id}"
                return 0
            fi

            local watch_json
            if ! watch_json=$(fetch_run_by_id "$GITHUB_REPO" "$run_id"); then
                log "API error while watching run ${run_id} (${elapsed_mins}m${elapsed_rem}s elapsed) — retrying"
                continue
            fi

            run_status=$(printf '%s' "$watch_json" | jq -r '.status')
            run_conclusion=$(printf '%s' "$watch_json" | jq -r '.conclusion // "null"')

            if [ "$run_status" = "completed" ]; then
                log "Run ${run_id} completed: ${run_conclusion} (SHA: ${run_sha:0:8}, elapsed: ${elapsed_mins}m${elapsed_rem}s)"
                break
            fi

            log "Run ${run_id} still ${run_status} (${elapsed_mins}m${elapsed_rem}s elapsed)..."
        done
    fi

    # Handle completed run
    if [ "$run_status" != "completed" ]; then
        log "Run ${run_id} is not completed (status=${run_status}) — skipping"
        return 0
    fi

    if [ "$run_conclusion" != "success" ]; then
        log "Run ${run_id} concluded with ${run_conclusion} — skipping deployment"
        notify_failure "$target" "CI run ${run_id} concluded with ${run_conclusion} (SHA: ${run_sha:0:8})"
        if [ "$DRY_RUN" != "true" ]; then
            update_state "$state_file" "{\"last_seen_run_id\": ${run_id}, \"last_seen_run_number\": ${run_number}, \"last_seen_run_attempt\": ${run_attempt}, \"last_seen_created_at\": \"${run_created_at}\", \"last_seen_head_sha\": \"${run_sha}\"}"
        else
            log "[DRY RUN] Would update state: last_seen_run_id=${run_id}"
        fi
        return 0
    fi

    if [ "$run_id" = "$deployed_run_id" ] && [ "$run_attempt" = "$deployed_run_attempt" ]; then
        log "Run ${run_id} attempt ${run_attempt} is already deployed (deployed_run_id + deployed_run_attempt match) — skipping redeploy"
        if [ "$DRY_RUN" != "true" ]; then
            update_state "$state_file" "{\"last_seen_run_id\": ${run_id}, \"last_seen_run_number\": ${run_number}, \"last_seen_run_attempt\": ${run_attempt}, \"last_seen_created_at\": \"${run_created_at}\", \"last_seen_head_sha\": \"${run_sha}\", \"status\": \"already_deployed\"}"
        else
            log "[DRY RUN] Would update state: already_deployed for run ${run_id}"
        fi
        return 0
    fi

    # New successful build — deploy
    log "New successful build (run ${run_id}). Deploying..."

    local deploy_ok=true
    if ! deploy "$target" "$run_id" "$run_sha" "$COMPOSE_FILE" "$cloudflare_purge" "$cloudflare_env" "$refresh_nginx"; then
        deploy_ok=false
    fi

    if [ "$deploy_ok" = "true" ]; then
        log "Deployment successful (run ${run_id}, SHA: ${run_sha:0:8})"
        notify_success "$target" "$run_id" "$run_sha"
        if [ "$DRY_RUN" != "true" ]; then
            local deployed_at
            deployed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            update_state "$state_file" \
                "{\"last_seen_run_id\": ${run_id}, \"last_seen_run_number\": ${run_number}, \"last_seen_run_attempt\": ${run_attempt}, \"last_seen_created_at\": \"${run_created_at}\", \"last_seen_head_sha\": \"${run_sha}\", \"deployed_run_id\": ${run_id}, \"deployed_run_attempt\": ${run_attempt}, \"sha\": \"${run_sha}\", \"deployed_at\": \"${deployed_at}\", \"status\": \"success\"}"
        else
            log "[DRY RUN] Would update state: last_seen_run_id=${run_id}, deployed_run_id=${run_id}, deployed_run_attempt=${run_attempt}"
        fi
    else
        log "ERROR: Deployment failed for run ${run_id}"
        notify_failure "$target" "Deployment failed for run ${run_id} — check logs/auto-redeploy/auto-redeploy.log"
        # Update last_seen_run_id so the same failed run isn't retried
        # deployed_run_id is intentionally left unchanged (still points to last good deployment)
        if [ "$DRY_RUN" != "true" ]; then
            update_state "$state_file" "{\"last_seen_run_id\": ${run_id}, \"last_seen_run_number\": ${run_number}, \"last_seen_run_attempt\": ${run_attempt}, \"last_seen_created_at\": \"${run_created_at}\", \"last_seen_head_sha\": \"${run_sha}\"}"
        else
            log "[DRY RUN] Would update state: last_seen_run_id=${run_id}"
        fi
    fi

    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$(dirname "$LOG_FILE")" || true  # may fail under systemd ProtectHome; install.sh guarantees dir exists
    CURRENT_TARGET="system"
    log "Starting auto-redeploy check"
    [ "$DRY_RUN" = "true" ] && log "DRY_RUN=true — no changes will be made"

    # Discover enabled targets (nullglob handles empty directory gracefully)
    shopt -s nullglob
    local conf_files=("${ENABLED_DIR}"/*.conf)
    shopt -u nullglob

    if [ "${#conf_files[@]}" -eq 0 ]; then
        log "No enabled targets found in ${ENABLED_DIR}"
        return 0
    fi

    log "Found ${#conf_files[@]} enabled target(s)"

    for conf in "${conf_files[@]}"; do
        # Skip broken symlinks or unreadable files
        if [ ! -f "$conf" ]; then
            CURRENT_TARGET="system"
            log "WARNING: ${conf} is not readable (broken symlink?) — skipping"
            continue
        fi

        local target
        target="$(basename "$conf" .conf)"
        CURRENT_TARGET="$target"

        if ! process_target "$conf" "$target"; then
            log "Error processing target — continuing to next"
        fi
    done

    CURRENT_TARGET="system"
    log "Auto-redeploy check complete"
}

main
exit 0
