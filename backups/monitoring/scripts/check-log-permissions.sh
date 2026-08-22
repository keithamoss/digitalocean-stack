#!/bin/bash
# Log Permissions Contract Check
# Validates root-managed, keith-managed, and container-managed log domains.
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

LOG_PERMISSIONS_POSTGRES_PATHS=(
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/db/postgresql"
)

# Additional runtime write paths used by systemd jobs that are not part of the pure
# log tree but still participate in the ownership/permission contract.
# Keep restore temp material in the keith-owned staging root, while archive and restore
# log destinations remain root-owned so they align with the root-only backup domain.
LOG_PERMISSIONS_RUNTIME_KEITH_PATHS=(
    "${STACK_DIR:-/home/keith/digitalocean-stack}/tmp"
)

LOG_PERMISSIONS_RUNTIME_ROOT_PATHS=(
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/restore/orchestration"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/restore/postgresql"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/restore/foundry"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/db/postgresql/archive"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/nginx/archive"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/docker/archive"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/consolidated/archive"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/postgres-full/archive"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/postgres-diff/archive"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/heartbeat/archive"
    "${STACK_DIR:-/home/keith/digitalocean-stack}/logs/backups/s3-cost-report/archive"
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
    local expected_mode="${4:-755}"

    if [[ ! -d "$path" ]]; then
        return 0
    fi

    local owner group mode
    owner=$(stat -c '%U' "$path" 2>/dev/null || echo "")
    group=$(stat -c '%G' "$path" 2>/dev/null || echo "")
    mode=$(stat -c '%a' "$path" 2>/dev/null || echo "")

    if [[ "$owner" != "$expected_owner" ]] || [[ "$group" != "$expected_group" ]]; then
        echo "ERROR: Ownership mismatch on $path: expected ${expected_owner}:${expected_group}, found ${owner}:${group}" >&2
        return 1
    fi

    if [[ "$mode" != "$expected_mode" ]]; then
        echo "ERROR: Mode mismatch on $path: expected ${expected_mode}, found ${mode}" >&2
        return 1
    fi

    if ! detect_acl_drift "$path"; then
        return 1
    fi

    return 0
}

# PostgreSQL's container user has no stable host username, so validate its
# bind-mounted writer path using numeric UID/GID values.
validate_numeric_log_path_contract() {
    local expected_uid="$1"
    local expected_gid="$2"
    local path="$3"
    local expected_mode="$4"

    if [[ ! -d "$path" ]]; then
        return 0
    fi

    local uid gid mode
    uid=$(stat -c '%u' "$path" 2>/dev/null || echo "")
    gid=$(stat -c '%g' "$path" 2>/dev/null || echo "")
    mode=$(stat -c '%a' "$path" 2>/dev/null || echo "")

    if [[ "$uid" != "$expected_uid" ]] || [[ "$gid" != "$expected_gid" ]]; then
        echo "ERROR: Ownership mismatch on $path: expected ${expected_uid}:${expected_gid}, found ${uid}:${gid}" >&2
        return 1
    fi

    if [[ "$mode" != "$expected_mode" ]]; then
        echo "ERROR: Mode mismatch on $path: expected ${expected_mode}, found ${mode}" >&2
        return 1
    fi

    if ! detect_acl_drift "$path"; then
        return 1
    fi

    return 0
}

# validate_log_permissions_system
#
# Validates the repo log contract across all managed ownership domains.
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

    local postgres_path
    for postgres_path in "${LOG_PERMISSIONS_POSTGRES_PATHS[@]}"; do
        if ! validate_numeric_log_path_contract "999" "999" "$postgres_path" "705"; then
            ((failures += 1))
        fi
    done

    local runtime_keith_path
    for runtime_keith_path in "${LOG_PERMISSIONS_RUNTIME_KEITH_PATHS[@]}"; do
        if ! validate_log_path_contract "keith" "keith" "$runtime_keith_path" "775"; then
            ((failures += 1))
        fi
    done

    local runtime_root_path
    for runtime_root_path in "${LOG_PERMISSIONS_RUNTIME_ROOT_PATHS[@]}"; do
        if ! validate_log_path_contract "root" "root" "$runtime_root_path" "755"; then
            ((failures += 1))
        fi
    done

    if ((failures > 0)); then
        echo "ERROR: Log permission contract check failed: ${failures} drift issue(s) detected" >&2
        return 1
    fi

    echo "Log permission contract check passed: root-managed paths are root:root 755; keith-managed paths are keith:keith 755; PostgreSQL live logs are 999:999 705; tmp is keith:keith 775; runtime write destinations conform to the scheduled-job contract"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if ! validate_log_permissions_system; then
        exit 1
    fi
fi
