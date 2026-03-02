#!/bin/bash
# postgresql-log-archive.sh
#
# Compress and archive PostgreSQL daily log files.
#
# PostgreSQL creates pre-dated log files (postgresql-YYYY-MM-DD.log) on its own schedule,
# so logrotate's rename-and-date-stamp approach would produce double-dated filenames.
# Instead, this script runs daily via systemd timer and:
#   1. Compresses all log files except today's active log
#   2. Moves compressed logs to the archive/ subdirectory
#   3. Deletes archives older than the retention period
#
# Produces: logs/db/postgresql/archive/postgresql-YYYY-MM-DD.log.gz

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
STACK_DIR="$(realpath "$SCRIPT_DIR/../..")"

LOG_DIR="$STACK_DIR/logs/db/postgresql"
ARCHIVE_DIR="$LOG_DIR/archive"
RETAIN_DAYS=60

TODAY=$(date +%Y-%m-%d)

echo "=== PostgreSQL Log Archive Started ==="
echo "Log directory : $LOG_DIR"
echo "Archive directory: $ARCHIVE_DIR"
echo "Retaining archives for $RETAIN_DAYS days"
echo "Today's date (excluded from archiving): $TODAY"
echo ""

# Ensure archive directory exists
mkdir -p "$ARCHIVE_DIR"

# Step 1: Compress all dated log files except today's active log
COMPRESSED=0
while IFS= read -r -d '' log_file; do
    echo "Compressing: $(basename "$log_file")"
    gzip -q "$log_file"
    COMPRESSED=$((COMPRESSED + 1))
done < <(find "$LOG_DIR" -maxdepth 1 -name "postgresql-*.log" ! -name "postgresql-${TODAY}.log" -print0)

echo "Compressed $COMPRESSED file(s)"
echo ""

# Step 2: Move all .gz files from the log directory into archive/
MOVED=0
while IFS= read -r -d '' gz_file; do
    echo "Archiving: $(basename "$gz_file")"
    mv "$gz_file" "$ARCHIVE_DIR/"
    MOVED=$((MOVED + 1))
done < <(find "$LOG_DIR" -maxdepth 1 -name "postgresql-*.log.gz" -print0)

echo "Moved $MOVED file(s) to archive/"
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
