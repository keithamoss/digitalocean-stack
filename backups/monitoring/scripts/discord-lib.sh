#!/bin/bash
# Shared Discord notification library
# Source this file to use send_discord function

# Function to send Discord notification
# Usage: send_discord "title" "description" color "emoji"
# Colors: green=5763719, red=15548997, yellow=16776960
send_discord() {
    local title="$1"
    local description="$2"
    local color="$3"
    local emoji="$4"
    
    if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
        echo "No Discord webhook configured, skipping notification"
        return 0
    fi
    
    # Check for jq dependency
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required for Discord notifications" >&2
        return 1
    fi
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Interpret escape sequences in description (convert \n to actual newlines)
    # then use jq to properly escape JSON strings (Issue 17)
    local description_interpreted
    description_interpreted=$(printf '%b' "$description")
    
    local payload
    payload=$(jq -n \
        --arg title "${emoji} ${title}" \
        --arg description "$description_interpreted" \
        --argjson color "${color}" \
        --arg timestamp "${timestamp}" \
        '{
            embeds: [{
                title: $title,
                description: $description,
                color: $color,
                timestamp: $timestamp,
                footer: {
                    text: "pi-hosting backup system"
                }
            }]
        }')
    
    if [[ -z "$payload" ]]; then
        echo "ERROR: Failed to build Discord payload" >&2
        return 1
    fi
    
    # Log Discord notification details (show interpreted version)
    echo "--- Discord Notification ---"
    echo "Title: ${emoji} ${title}"
    echo "Color: ${color}"
    echo "Description:"
    printf '%b\n' "$description"
    echo "---------------------------"
    
    # POST to Discord webhook, with one retry on 429 (honoring retry_after).
    local attempt header_file curl_output curl_exit_code http_status body
    local rl_limit rl_remaining rl_reset rl_reset_after rl_scope rl_bucket retry_after

    for attempt in 1 2; do
        header_file=$(mktemp)
        curl_exit_code=0

        curl_output=$(curl -sS -D "$header_file" -w "\nHTTP_STATUS:%{http_code}" \
            -X POST "${DISCORD_WEBHOOK_URL}" \
            -H "Content-Type: application/json" \
            -d "${payload}" 2>&1) || curl_exit_code=$?

        if [[ "$curl_exit_code" -ne 0 ]]; then
            rm -f "$header_file"
            echo "ERROR: curl failed with exit code ${curl_exit_code}" >&2
            echo "Output: ${curl_output}" >&2
            return 1
        fi

        http_status=$(echo "$curl_output" | grep "HTTP_STATUS:" | cut -d: -f2)
        body=$(echo "$curl_output" | grep -v "^HTTP_STATUS:")

        if [[ "$http_status" == "429" ]]; then
            # Extract and log rate-limit headers for diagnostics
            rl_limit=$(     grep -i "^X-RateLimit-Limit:"       "$header_file" | tr -d '\r' | awk '{print $2}')
            rl_remaining=$( grep -i "^X-RateLimit-Remaining:"   "$header_file" | tr -d '\r' | awk '{print $2}')
            rl_reset=$(     grep -i "^X-RateLimit-Reset:"       "$header_file" | tr -d '\r' | awk '{print $2}')
            rl_reset_after=$(grep -i "^X-RateLimit-Reset-After:" "$header_file" | tr -d '\r' | awk '{print $2}')
            rl_scope=$(     grep -i "^X-RateLimit-Scope:"       "$header_file" | tr -d '\r' | awk '{print $2}')
            rl_bucket=$(    grep -i "^X-RateLimit-Bucket:"      "$header_file" | tr -d '\r' | awk '{print $2}')
            rm -f "$header_file"

            echo "ERROR: Discord webhook returned HTTP status 429" >&2
            echo "Response: ${body}" >&2
            echo "HTTP_STATUS:429" >&2
            echo "Rate-Limit: Limit=${rl_limit:-?} Remaining=${rl_remaining:-?} Reset=${rl_reset:-?} Reset-After=${rl_reset_after:-?} Scope=${rl_scope:-?} Bucket=${rl_bucket:-?}" >&2

            if [[ "$attempt" -eq 2 ]]; then
                echo "ERROR: Failed to send Discord notification after retry" >&2
                return 1
            fi

            # Parse retry_after from JSON body; fall back to Reset-After header or 5s
            retry_after=$(printf '%s' "$body" | jq -r '.retry_after // empty' 2>/dev/null)
            [[ -z "$retry_after" ]] && retry_after="${rl_reset_after:-5}"
            echo "Rate-limited by Discord; retrying after ${retry_after}s (attempt ${attempt}/2)..." >&2
            sleep "$retry_after"
            continue
        fi

        rm -f "$header_file"

        # Check for other HTTP failures
        if [[ -z "$http_status" ]] || [[ "$http_status" -lt 200 ]] || [[ "$http_status" -ge 300 ]]; then
            echo "ERROR: Discord webhook returned HTTP status ${http_status:-unknown}" >&2
            echo "Response: ${curl_output}" >&2
            return 1
        fi

        echo "Discord notification sent successfully (HTTP ${http_status})"
        return 0
    done

    return 1
}
