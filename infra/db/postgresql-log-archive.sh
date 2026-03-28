#!/bin/bash
# postgresql-log-archive.sh
#
# Compress and archive PostgreSQL daily log files.
#
# PostgreSQL creates pre-dated log files (postgresql-YYYY-MM-DD.log) on its own schedule,
# so logrotate's rename-and-date-stamp approach would produce double-dated filenames.
# Instead, this script runs daily via systemd timer and:
#   1. Moves all log files except the most recently modified one to archive/ (uncompressed)
#   2. Compresses all uncompressed logs in archive/ except the most recently moved one
#   3. Deletes archives older than the retention period
#
# Using newest-by-mtime (not today's date) is more robust — e.g. if the timer
# fires before PostgreSQL has created today's file.
#
# Produces: logs/db/postgresql/archive/postgresql-YYYY-MM-DD.log.gz

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
STACK_DIR="$(realpath "$SCRIPT_DIR/../..")"

LOG_DIR="$STACK_DIR/logs/db/postgresql"
ARCHIVE_DIR="$LOG_DIR/archive"
RETAIN_DAYS=60

echo "=== PostgreSQL Log Archive Started ==="
echo "Log directory    : $LOG_DIR"
echo "Archive directory: $ARCHIVE_DIR"
echo "Retaining archives for $RETAIN_DAYS days"
echo ""

# Ensure archive directory exists
mkdir -p "$ARCHIVE_DIR"

# Find the most recently modified log file in the live dir — this one stays in place
NEWEST=$(find "$LOG_DIR" -maxdepth 1 -name "postgresql-*.log" -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d' ' -f2-)

# Step 1: Move all log files except the newest into archive/ (uncompressed)
MOVED=0
if [[ -n "$NEWEST" ]]; then
    echo "Keeping in live directory: $(basename "$NEWEST")"
    echo ""
    while IFS= read -r -d '' log_file; do
        [[ "$log_file" == "$NEWEST" ]] && continue
        echo "Moving to archive: $(basename "$log_file")"
        mv "$log_file" "$ARCHIVE_DIR/"
        MOVED=$((MOVED + 1))
    done < <(find "$LOG_DIR" -maxdepth 1 -name "postgresql-*.log" -print0)
else
    echo "No log files in live directory"
    echo ""
fi
echo "Moved $MOVED file(s) to archive/"
echo ""

# Step 2: Compress all uncompressed log files in archive/ except the most recently moved one
NEWEST_ARCHIVE=$(find "$ARCHIVE_DIR" -maxdepth 1 -name "postgresql-*.log" -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d' ' -f2-)

COMPRESSED=0
if [[ -n "$NEWEST_ARCHIVE" ]]; then
    echo "Keeping uncompressed in archive (delay): $(basename "$NEWEST_ARCHIVE")"
    while IFS= read -r -d '' log_file; do
        [[ "$log_file" == "$NEWEST_ARCHIVE" ]] && continue
        echo "Compressing: $(basename "$log_file")"
        gzip -q "$log_file"
        COMPRESSED=$((COMPRESSED + 1))
    done < <(find "$ARCHIVE_DIR" -maxdepth 1 -name "postgresql-*.log" -print0)
fi
echo "Compressed $COMPRESSED file(s)"
echo ""

# Step 3: Delete archives older than the retention period
DELETED=0
while IFS= read -r -d '' old_file; do
    echo "Deleting expired archive: $(basename "$old_file")"
    rm "$old_file"
    DELETED=$((DELETED + 1))
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -name "postgresql-*.log.gz" -mtime +"$RETAIN_DAYS" -print0)

echo "Deleted $DELETED expired archive(s)"
echo ""
echo "=== PostgreSQL Log Archive Complete ==="
