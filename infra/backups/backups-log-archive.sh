#!/bin/bash
# backups-log-archive.sh
#
# Compress and archive backup wrapper log files.
#
# Backup wrappers create pre-dated log files (e.g. diff-backup-YYYY-MM-DD.log),
# so logrotate's rename-and-date-stamp approach would produce double-dated filenames.
# Instead, this script runs daily via systemd timer and for each backup log directory:
#   1. Compresses all log files except the most recently modified one
#   2. Moves compressed logs to the archive/ subdirectory
#   3. Deletes archives older than the retention period
#
# Modelled on infra/db/postgresql-log-archive.sh.
#
# Directories handled:
#   logs/backups/docker-logs/   docker-logs-export_*.log
#   logs/backups/foundry/       backup-*.log
#   logs/backups/heartbeat/     heartbeat-*.log
#   logs/backups/postgres-diff/ diff-backup-*.log
#   logs/backups/postgres-full/ full-backup-*.log

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
STACK_DIR="$(realpath "$SCRIPT_DIR/../..")"

BACKUPS_LOG_DIR="$STACK_DIR/logs/backups"
RETAIN_DAYS=60

echo "=== Backup Log Archive Started ==="
echo "Log base directory: $BACKUPS_LOG_DIR"
echo "Retaining archives for $RETAIN_DAYS days"
echo ""

# archive_logs LOG_DIR PATTERN
#
# Compress all log files matching PATTERN in LOG_DIR except the most recently
# modified one, move compressed files to LOG_DIR/archive/, and delete archives
# older than RETAIN_DAYS.
#
# Arguments:
#   $1  LOG_DIR  - directory containing the dated log files
#   $2  PATTERN  - glob pattern matching log files (e.g. "diff-backup-*.log")
archive_logs() {
    local log_dir="$1"
    local pattern="$2"
    local archive_dir="$log_dir/archive"

    echo "--- Processing: $log_dir ---"

    if [[ ! -d "$log_dir" ]]; then
        echo "  Directory does not exist, skipping"
        echo ""
        return
    fi

    mkdir -p "$archive_dir"

    # Find the most recently modified file matching the pattern
    local newest
    newest=$(find "$log_dir" -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-)

    if [[ -z "$newest" ]]; then
        echo "  No log files found matching $pattern"
        echo ""
        return
    fi

    echo "  Keeping uncompressed: $(basename "$newest")"

    # Step 1: Compress all matching files except the newest
    local compressed=0
    while IFS= read -r -d '' log_file; do
        [[ "$log_file" == "$newest" ]] && continue
        echo "  Compressing: $(basename "$log_file")"
        gzip -q "$log_file"
        compressed=$((compressed + 1))
    done < <(find "$log_dir" -maxdepth 1 -name "$pattern" -print0)

    echo "  Compressed $compressed file(s)"

    # Step 2: Move compressed files into archive/
    # gz filenames match the log pattern with .gz appended (gzip preserves the name)
    local gz_pattern="${pattern%.log}.log.gz"
    local moved=0
    while IFS= read -r -d '' gz_file; do
        echo "  Archiving: $(basename "$gz_file")"
        mv "$gz_file" "$archive_dir/"
        moved=$((moved + 1))
    done < <(find "$log_dir" -maxdepth 1 -name "$gz_pattern" -print0)

    echo "  Moved $moved file(s) to archive/"

    # Step 3: Delete archives older than the retention period
    local deleted=0
    while IFS= read -r -d '' old_file; do
        echo "  Deleting expired archive: $(basename "$old_file")"
        rm "$old_file"
        deleted=$((deleted + 1))
    done < <(find "$archive_dir" -maxdepth 1 -name "*.gz" -mtime +"$RETAIN_DAYS" -print0)

    echo "  Deleted $deleted expired archive(s)"
    echo ""
}

archive_logs "$BACKUPS_LOG_DIR/docker-logs"   "docker-logs-export_*.log"
archive_logs "$BACKUPS_LOG_DIR/foundry"        "backup-*.log"
archive_logs "$BACKUPS_LOG_DIR/heartbeat"      "heartbeat-*.log"
archive_logs "$BACKUPS_LOG_DIR/postgres-diff"  "diff-backup-*.log"
archive_logs "$BACKUPS_LOG_DIR/postgres-full"  "full-backup-*.log"

echo "=== Backup Log Archive Complete ==="
