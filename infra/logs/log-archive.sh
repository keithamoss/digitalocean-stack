#!/bin/bash
# log-archive.sh
#
# Compress and archive operational log files for scripts that write pre-dated
# log files (e.g. backup-YYYY-MM-DD.log, restore-test-YYYY-MM-DD.log).
#
# logrotate's rename-and-date-stamp approach would produce double-dated filenames
# for these files, so this script handles archival instead. It runs daily via
# systemd timer and for each log directory:
#   1. Moves all log files except the most recently modified one to archive/ (uncompressed)
#   2. Compresses all uncompressed logs in archive/ except the most recently moved one
#   3. Deletes archives older than the retention period
#
# Modelled on infra/db/postgresql-log-archive.sh.
#
# Directories handled:
#   logs/backups/configs-backup/ backup-*.log
#   logs/backups/consolidated/   run-*.log
#   logs/backups/docker-logs/    docker-logs-export_*.log
#   logs/backups/foundry/        backup-*.log
#   logs/backups/heartbeat/      heartbeat-*.log
#   logs/backups/logs-backup/    backup-*.log
#   logs/backups/postgres-diff/  diff-backup-*.log
#   logs/backups/postgres-full/  full-backup-*.log
#   logs/restore/                restore-test-*.log

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
STACK_DIR="$(realpath "$SCRIPT_DIR/../..")"

BACKUPS_LOG_DIR="$STACK_DIR/logs/backups"
RESTORE_LOG_DIR="$STACK_DIR/logs/restore"
RETAIN_DAYS=60

echo "=== Log Archive Started ==="
echo "Backup log base: $BACKUPS_LOG_DIR"
echo "Restore log base: $RESTORE_LOG_DIR"
echo "Retaining archives for $RETAIN_DAYS days"
echo ""

# archive_logs LOG_DIR PATTERN
#
# Move all log files matching PATTERN in LOG_DIR (except the most recently modified
# one) to LOG_DIR/archive/ uncompressed, compress all but the most recently moved
# uncompressed file in archive/, and delete archives older than RETAIN_DAYS.
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

    # Find the most recently modified file matching the pattern in the live dir
    local newest
    newest=$(find "$log_dir" -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-)

    # Step 1: Move all log files except the newest into archive/ (uncompressed)
    local moved=0
    if [[ -n "$newest" ]]; then
        echo "  Keeping in live directory: $(basename "$newest")"
        while IFS= read -r -d '' log_file; do
            [[ "$log_file" == "$newest" ]] && continue
            echo "  Moving to archive: $(basename "$log_file")"
            mv "$log_file" "$archive_dir/"
            moved=$((moved + 1))
        done < <(find "$log_dir" -maxdepth 1 -name "$pattern" -print0)
    else
        echo "  No log files found matching $pattern in live directory"
    fi
    echo "  Moved $moved file(s) to archive/"

    # Step 2: Compress all uncompressed log files in archive/ except the most recently moved one
    local newest_archive
    newest_archive=$(find "$archive_dir" -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-)

    local compressed=0
    if [[ -n "$newest_archive" ]]; then
        echo "  Keeping uncompressed in archive (delay): $(basename "$newest_archive")"
        while IFS= read -r -d '' log_file; do
            [[ "$log_file" == "$newest_archive" ]] && continue
            echo "  Compressing: $(basename "$log_file")"
            gzip -q "$log_file"
            compressed=$((compressed + 1))
        done < <(find "$archive_dir" -maxdepth 1 -name "$pattern" -print0)
    fi
    echo "  Compressed $compressed file(s)"

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

archive_logs "$BACKUPS_LOG_DIR/configs-backup" "backup-*.log"
archive_logs "$BACKUPS_LOG_DIR/consolidated"   "run-*.log"
archive_logs "$BACKUPS_LOG_DIR/docker-logs"    "docker-logs-export_*.log"
archive_logs "$BACKUPS_LOG_DIR/foundry"        "backup-*.log"
archive_logs "$BACKUPS_LOG_DIR/heartbeat"      "heartbeat-*.log"
archive_logs "$BACKUPS_LOG_DIR/logs-backup"    "backup-*.log"
archive_logs "$BACKUPS_LOG_DIR/postgres-diff"  "diff-backup-*.log"
archive_logs "$BACKUPS_LOG_DIR/postgres-full"  "full-backup-*.log"
archive_logs "$RESTORE_LOG_DIR"               "restore-test-*.log"

echo "=== Log Archive Complete ==="
