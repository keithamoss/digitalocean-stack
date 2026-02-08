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
    
    # Issue 11: Better error handling - capture curl output and http status
    local curl_output
    local curl_exit_code
    curl_output=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" -X POST "${DISCORD_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>&1) || curl_exit_code=$?
    
    # Check for curl failure
    if [[ -n "${curl_exit_code:-}" ]]; then
        echo "ERROR: curl failed with exit code ${curl_exit_code}" >&2
        echo "Output: ${curl_output}" >&2
        return 1
    fi
    
    # Extract HTTP status code
    local http_status=$(echo "$curl_output" | grep "HTTP_STATUS:" | cut -d: -f2)
    
    # Check HTTP status
    if [[ -z "$http_status" ]] || [[ "$http_status" -lt 200 ]] || [[ "$http_status" -ge 300 ]]; then
        echo "ERROR: Discord webhook returned HTTP status ${http_status:-unknown}" >&2
        echo "Response: ${curl_output}" >&2
        return 1
    fi
    
    echo "Discord notification sent successfully (HTTP ${http_status})"
}
