#!/bin/bash
# Log Permissions Contract Check
# Validates root-managed and keith-managed log domains match the repo contract.
#
# This script is sourced by backup-status.sh and can also be run directly.

# Contract: use pure owner/group/mode; no ACL-based write grants in steady state.

LOG_PERMISSIONS_ROOT_PATHS=(
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/nginx"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/db"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/restore"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/consolidated"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/postgres-full"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/postgres-diff"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/heartbeat"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/s3-cost-report"
)

LOG_PERMISSIONS_KEITH_PATHS=(
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/auto-redeploy"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/docker"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/foundry"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/docker-logs"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/logs-backup"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/operational-backup"
)

# detect_acl_drift
#
# Returns 0 if no named-user/group ACL entries or mask/default-mask entries are present.
# Returns 1 if ACL drift is detected.
#
# This deliberately treats named user/group ACLs and masks as drift because the
# contract requires pure owner/group/mode policy in steady state.
detect_acl_drift() {
    local path="$1"

    if [[ ! -e "$path" ]]; then
        return 0
    fi

    if ! command -v getfacl >/dev/null 2>&1; then
        return 0
    fi

    local acl_output
    acl_output=$(getfacl -cp "$path" 2>/dev/null || true)
    if [[ -z "$acl_output" ]]; then
        return 0
    fi

    if echo "$acl_output" | grep -Eq '^(user:[^:]+:|group:[^:]+:|default:user:[^:]+:|default:group:[^:]+:|mask:|default:mask:)'; then
        echo "ACL drift detected on $path" >&2
        echo "$acl_output" >&2
        return 1
    fi

    return 0
}

# validate_log_path_contract
#
# Validates ownership, mode, and ACL cleanliness for a single path.
# Arguments:
#   $1 - expected owner (root or keith)
#   $2 - expected group (root or keith)
#   $3 - path
#
# Returns 0 on success, 1 on drift.
validate_log_path_contract() {
    local expected_owner="$1"
    local expected_group="$2"
    local path="$3"

    if [[ ! -d "$path" ]]; then
        echo "ERROR: Missing log directory: $path" >&2
        return 1
    fi

    local owner group mode
    owner=$(stat -c '%U' "$path" 2>/dev/null || echo "")
    group=$(stat -c '%G' "$path" 2>/dev/null || echo "")
    mode=$(stat -c '%a' "$path" 2>/dev/null || echo "")

    if [[ "$owner" != "$expected_owner" ]] || [[ "$group" != "$expected_group" ]]; then
        echo "ERROR: Ownership mismatch on $path: expected ${expected_owner}:${expected_group}, found ${owner}:${group}" >&2
        return 1
    fi

    if [[ "$mode" != "755" ]]; then
        echo "ERROR: Mode mismatch on $path: expected 755, found ${mode}" >&2
        return 1
    fi

    if ! detect_acl_drift "$path"; then
        return 1
    fi

    return 0
}

# validate_log_permissions_system
#
# Validates the repo log contract against both root-managed and keith-managed domains.
# Returns 0 when all checked paths conform; 1 when drift is detected.
validate_log_permissions_system() {
    local failures=0

    local root_path
    for root_path in "${LOG_PERMISSIONS_ROOT_PATHS[@]}"; do
        if ! validate_log_path_contract "root" "root" "$root_path"; then
            ((failures += 1))
        fi
    done

    local keith_path
    for keith_path in "${LOG_PERMISSIONS_KEITH_PATHS[@]}"; do
        if ! validate_log_path_contract "keith" "keith" "$keith_path"; then
            ((failures += 1))
        fi
    done

    if ((failures > 0)); then
        echo "ERROR: Log permission contract check failed: ${failures} drift issue(s) detected" >&2
        return 1
    fi

    echo "Log permission contract check passed: root-managed paths are root:root 755; keith-managed paths are keith:keith 755"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if ! validate_log_permissions_system; then
        exit 1
    fi
fi
