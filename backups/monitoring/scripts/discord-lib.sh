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
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local payload=$(cat <<EOF
{
  "embeds": [{
    "title": "${emoji} ${title}",
    "description": "${description}",
    "color": ${color},
    "timestamp": "${timestamp}",
    "footer": {
      "text": "pi-hosting backup system"
    }
  }]
}
EOF
)
    
    curl -sS -X POST "${DISCORD_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "${payload}" > /dev/null || {
        echo "Failed to send Discord notification"
        return 1
    }
}
