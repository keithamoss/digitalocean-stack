#!/usr/bin/env bash
set -euo pipefail

# Bidirectional Postgres migration helper (Pi ↔ DigitalOcean)
# Requirements: psql, pg_dump, pg_restore, vacuumdb, python3; connection details must come from an .env file.
# Example invocations:
#   # Pi → DigitalOcean
#   bash db/migrate_db.sh --direction pi-to-do --config /tmp/migrate.env
#   
#   # DigitalOcean → Pi (bring database home)
#   bash db/migrate_db.sh --direction do-to-pi --config /tmp/migrate.env
#
# See migrate.example.env for configuration structure.

# Future improvements:
# - Disk/headroom checks before dumps
# - Multi-database support (loop over DBs)
# - DO CLI integration (create cluster, add replicas, configure backups)

# Direction control
DIRECTION=""
RENAME_SOURCE=""

# Runtime variables loaded from config (SOURCE_*/TARGET_* directly from .env)
SOURCE_HOST=""
SOURCE_PORT=""
SOURCE_USER=""
SOURCE_PASS=""
SOURCE_SSLMODE=""
SOURCE_ADMIN_DB=""
SOURCE_APP_ROLE=""
SOURCE_URL=""
SOURCE_LABEL=""
TARGET_HOST=""
TARGET_PORT=""
TARGET_USER=""
TARGET_PASS=""
TARGET_SSLMODE=""
TARGET_ADMIN_DB=""
TARGET_APP_ROLE=""
TARGET_APP_ROLE_PASSWORD=""
TARGET_URL=""
TARGET_LABEL=""

# Database & migration settings
DB_NAME=""
SCHEMA_NAME=""
DUMP_FILE=""
WAIT_SLEEP=${WAIT_SLEEP:-2}
WAIT_MAX_ATTEMPTS=${WAIT_MAX_ATTEMPTS:-0}
LOG_FILE=""
CONFIG_FILE=""
PG_DUMP_BIN=${PG_DUMP_BIN:-pg_dump}
PG_RESTORE_BIN=${PG_RESTORE_BIN:-pg_restore}
PG_RESTORE_JOBS=${PG_RESTORE_JOBS:-4}

# Version handling
EXIT_MISSING_VARS=10
EXIT_PRECHECK=11
EXIT_CONN_FAIL=12
EXIT_TARGET_NOT_EMPTY=13
EXIT_WAIT_TIMEOUT=15
EXIT_DUMP_FAIL=16
EXIT_RESTORE_FAIL=17
EXIT_VERIFY_FAIL=18
EXIT_DB_MISSING=19
EXIT_VERSION_MISMATCH=20
EXIT_TARGET_DB_MISSING=21

SCRIPT_START_TIME=""
STEP_START_TIME=""
FROZEN=0
FROZEN_DB_NAME=""

# --- Helpers ---

# Percent-encode connection components to tolerate special characters
url_encode_component() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

# Build a postgres:// URL from parts if full URL not supplied (components are encoded)
build_url_from_parts() {
  local user_enc pass_enc db_enc host="$3" port="$4" sslmode="$6"
  user_enc=$(url_encode_component "$1")
  pass_enc=$(url_encode_component "$2")
  db_enc=$(url_encode_component "$5")
  local auth="$user_enc"
  [[ -n "$2" ]] && auth="$auth:$pass_enc"
  echo "postgres://${auth}@${host}${port:+:$port}/${db_enc}?sslmode=${sslmode}"
}

# Redact password from postgres:// connection URLs for safe logging
redact_url() {
  echo "$1" | sed -E 's|(postgres://[^:]+:)[^@]+(@)|\1****\2|'
}

# Log a message to stdout and the log file with timestamp
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  if [[ -n "$LOG_FILE" ]]; then
    echo "$msg" | tee -a "$LOG_FILE"
  else
    echo "$msg"
  fi
}

# Mark the start of a timed step; logs the step name
step_start() {
  STEP_START_TIME=$(date +%s)
  log "$1"
}

# Mark the end of a timed step; logs elapsed seconds
step_end() {
  local elapsed=$(($(date +%s) - STEP_START_TIME))
  log "  ↳ completed in ${elapsed}s"
  echo "" | tee -a "$LOG_FILE"
}

print_help() {
  cat <<'EOF'
Usage: bash db/migrate_db.sh --direction <direction> --config <path> [options]

Required:
  --direction pi-to-do|do-to-pi  Migration direction
  --config PATH                   .env file with DB_NAME, SCHEMA_NAME, SOURCE_*, TARGET_* variables

Help:
  -h, --help                     Show this message

Configuration file must contain (see migrate.example.env):
  DB_NAME, SCHEMA_NAME, RENAME_SOURCE (true|false)
  SOURCE_HOST, SOURCE_PORT, SOURCE_USER, SOURCE_PASS, SOURCE_SSLMODE, SOURCE_ADMIN_DB, SOURCE_APP_ROLE
  TARGET_HOST, TARGET_PORT, TARGET_USER, TARGET_PASS, TARGET_SSLMODE, TARGET_ADMIN_DB, TARGET_APP_ROLE
  TARGET_APP_ROLE_PASSWORD (required - role will be created with LOGIN capability)

Examples:
  # Migrate from Pi to DigitalOcean
  bash db/migrate_db.sh --direction pi-to-do --config /tmp/migrate.env
  
  # Bring database home from DO to Pi
  bash db/migrate_db.sh --direction do-to-pi --config /tmp/migrate.env
  
  # Set RENAME_SOURCE=true in the .env file to rename source after migration
  # Set RENAME_SOURCE=false to keep source database name unchanged
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --direction)
        DIRECTION="$2"
        shift 2;;
      --config)
        CONFIG_FILE="$2"
        [[ -f "$CONFIG_FILE" ]] || { echo "Config not found: $CONFIG_FILE"; exit 1; }
        load_env_file "$CONFIG_FILE"
        shift 2;;
      -h|--help) print_help; exit 0;;
      *) echo "Unknown argument: $1"; echo "Use --help for usage."; exit 1;;
    esac
  done
}

# Guidance for installing matching client binaries
print_pg_client_install_help() {
  local target_major="$1"
  log "Install matching client tools (Debian/Ubuntu):"
  log "sudo apt install -y postgresql-common"
  log "sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh"
  log "sudo apt-get install postgresql-client-$target_major"
  log "Or set PG_DUMP_BIN/PG_RESTORE_BIN to paths for the desired major (e.g., /usr/lib/postgresql/$target_major/bin/pg_dump)."
}

# Load config from a POSIX-style .env file
load_env_file() {
  local file="$1"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

# Parse direction and set labels based on direction
parse_direction() {
  [[ -z "$DIRECTION" ]] && { log "Missing required --direction parameter"; exit $EXIT_MISSING_VARS; }
  
  case "$DIRECTION" in
    pi-to-do)
      SOURCE_LABEL="Pi"
      TARGET_LABEL="DO"
      ;;
    do-to-pi)
      SOURCE_LABEL="DO"
      TARGET_LABEL="Pi"
      ;;
    *)
      log "Invalid direction: $DIRECTION"
      log "Must be 'pi-to-do' or 'do-to-pi'"
      exit $EXIT_MISSING_VARS
      ;;
  esac
  
  # Validate all required variables are set
  local required_vars=(
    "DB_NAME" "SCHEMA_NAME" "RENAME_SOURCE"
    "SOURCE_HOST" "SOURCE_PORT" "SOURCE_USER" "SOURCE_SSLMODE" 
    "SOURCE_ADMIN_DB" "SOURCE_APP_ROLE"
    "TARGET_HOST" "TARGET_PORT" "TARGET_USER" "TARGET_SSLMODE"
    "TARGET_ADMIN_DB" "TARGET_APP_ROLE" "TARGET_APP_ROLE_PASSWORD"
  )
  
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
      log "Missing required variable: $var"
      log "All connection parameters must be specified in config file"
      exit $EXIT_MISSING_VARS
    fi
  done
  
  # Validate RENAME_SOURCE value
  if [[ "$RENAME_SOURCE" != "true" && "$RENAME_SOURCE" != "false" ]]; then
    log "Invalid value for RENAME_SOURCE: $RENAME_SOURCE (must be 'true' or 'false')"
    exit $EXIT_MISSING_VARS
  fi
}

# Check for old migrated databases on source to warn user
check_for_old_migrations() {
  local admin_url count
  admin_url=$(build_url_from_parts "$SOURCE_USER" "$SOURCE_PASS" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_ADMIN_DB" "$SOURCE_SSLMODE")
  count=$(psql "$admin_url" -Atqc "SELECT count(*) FROM pg_database WHERE datname LIKE '${DB_NAME}_migrated_%';" 2>/dev/null || echo "0")
  if [[ "$count" -gt 0 ]]; then
    log "Warning: Found $count existing migrated database(s) matching '${DB_NAME}_migrated_*' on source"
    log "Consider cleaning up old migrations manually if no longer needed"
  fi
}

# Ensure a command exists on PATH; exit with error if missing
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "Missing required command: $1"; exit $EXIT_PRECHECK; }
}

# Capture server and PostGIS versions for compatibility warnings
get_pg_version() {
  psql "$1" -Atqc "SHOW server_version;"
}

get_postgis_version() {
  psql "$1" -Atqc "SELECT postgis_version();" 2>/dev/null || echo "none"
}

parse_major() {
  echo "${1%%.*}"
}

get_client_major() {
  local bin="$1" ver
  ver=$("$bin" --version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) {print $i; exit}}')
  [[ -n "$ver" ]] && parse_major "$ver"
}

select_pg_binaries() {
  local target_major="$1"
  # For cross-major migrations, we MUST use client tools matching the target version exactly
  # Using newer client tools can emit SQL that older target servers don't understand
  if [[ -x "/usr/lib/postgresql/$target_major/bin/pg_dump" ]]; then
    PG_DUMP_BIN="/usr/lib/postgresql/$target_major/bin/pg_dump"
    PG_RESTORE_BIN="/usr/lib/postgresql/$target_major/bin/pg_restore"
    log "Selected exact match: pg_dump/pg_restore $target_major at $PG_DUMP_BIN"
    return 0
  fi
  
  # No exact match found - this is a hard requirement for cross-major migrations
  return 1
}

check_client_versions_against_target() {
  local target_pg target_major source_pg source_major dump_major restore_major admin_url
  admin_url=$(build_url_from_parts "$TARGET_USER" "$TARGET_PASS" "$TARGET_HOST" "$TARGET_PORT" "$TARGET_ADMIN_DB" "$TARGET_SSLMODE")
  target_pg=$(get_pg_version "$admin_url")
  target_major=$(parse_major "$target_pg")
  
  # Get source version to determine if this is a cross-major migration
  local source_admin_url
  source_admin_url=$(build_url_from_parts "$SOURCE_USER" "$SOURCE_PASS" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_ADMIN_DB" "$SOURCE_SSLMODE")
  source_pg=$(get_pg_version "$source_admin_url")
  source_major=$(parse_major "$source_pg")

  # Prefer binaries that match the target major for cross-major migrations
  select_pg_binaries "$target_major" || true

  if ! command -v "$PG_DUMP_BIN" >/dev/null 2>&1; then
    log "Missing pg_dump at $PG_DUMP_BIN"
    print_pg_client_install_help "$target_major"
    exit $EXIT_PRECHECK
  fi
  if ! command -v "$PG_RESTORE_BIN" >/dev/null 2>&1; then
    log "Missing pg_restore at $PG_RESTORE_BIN"
    print_pg_client_install_help "$target_major"
    exit $EXIT_PRECHECK
  fi

  dump_major=$(get_client_major "$PG_DUMP_BIN")
  restore_major=$(get_client_major "$PG_RESTORE_BIN")
  if [[ -z "$dump_major" || -z "$restore_major" ]]; then
    log "Unable to detect pg_dump/pg_restore major versions from $PG_DUMP_BIN / $PG_RESTORE_BIN; proceeding without version guard."
    return 0
  fi
  
  # PostgreSQL best practice: for cross-major upgrades, use client tools matching the NEWER (target) version
  if [[ "$source_major" != "$target_major" ]]; then
    log "Cross-major migration detected: source $source_major → target $target_major"
    log "Client tools: pg_dump $dump_major, pg_restore $restore_major"
    
    # CRITICAL: For cross-major migrations, client tools must EXACTLY match target version
    # Newer tools emit SQL that older servers may not understand (e.g., pg_restore 17 emits transaction_timeout for PG 16)
    if [[ "$dump_major" != "$target_major" || "$restore_major" != "$target_major" ]]; then
      log ""
      log "ERROR: Client tools must exactly match target PostgreSQL version for cross-major migrations!"
      log "PostgreSQL $target_major → requires pg_dump/pg_restore version $target_major (not newer, not older)"
      log ""
      log "Current tools:"
      log "  pg_dump: version $dump_major (at $PG_DUMP_BIN)"
      log "  pg_restore: version $restore_major (at $PG_RESTORE_BIN)"
      log ""
      log "Required: exactly version $target_major"
      log ""
      log "Why: Newer client tools emit SQL for features that older servers don't support."
      log "     Example: pg_restore 17 emits 'SET transaction_timeout' which PG 16 rejects."
      log ""
      print_pg_client_install_help "$target_major"
      log ""
      log "After installing, ensure /usr/lib/postgresql/$target_major/bin is in PATH before other versions,"
      log "or set PG_DUMP_BIN=/usr/lib/postgresql/$target_major/bin/pg_dump"
      log "    and PG_RESTORE_BIN=/usr/lib/postgresql/$target_major/bin/pg_restore"
      exit $EXIT_VERSION_MISMATCH
    fi
    
    log "✓ Client tools exactly match target version (required for cross-major upgrade)"
  else
    # Same-major migration: any version is generally OK
    if [[ "$dump_major" != "$target_major" || "$restore_major" != "$target_major" ]]; then
      log "Note: Client tools ($dump_major/$restore_major) differ from target $target_major, but same-major migration allows this."
    else
      log "✓ Client tools align with target major: pg_dump $dump_major, pg_restore $restore_major; target server: $target_major"
    fi
  fi
}

check_versions() {
  log "Checking Postgres/PostGIS versions..."
  local source_pg target_pg source_pg_major target_pg_major source_postgis target_postgis
  source_pg=$(get_pg_version "$SOURCE_URL")
  target_pg=$(get_pg_version "$TARGET_URL")
  source_pg_major=${source_pg%%.*}
  target_pg_major=${target_pg%%.*}
  log "  $SOURCE_LABEL Postgres: $source_pg"
  log "  $TARGET_LABEL Postgres: $target_pg"
  if [[ "$target_pg_major" -lt "$source_pg_major" ]]; then
    log "Target Postgres major version ($target_pg_major) is older than source ($source_pg_major); downgrades are not supported by pg_dump/pg_restore."
    exit $EXIT_VERSION_MISMATCH
  elif [[ "$target_pg_major" -gt "$source_pg_major" ]]; then
    log "Note: Target Postgres major is newer; pg_dump/pg_restore supports upgrades, verify extensions as needed."
  fi

  source_postgis=$(get_postgis_version "$SOURCE_URL")
  target_postgis=$(get_postgis_version "$TARGET_URL")
  log "  $SOURCE_LABEL PostGIS: $source_postgis"
  log "  $TARGET_LABEL PostGIS: $target_postgis"
  if [[ "$source_postgis" != "none" && "$target_postgis" == "none" ]]; then
    log "Target lacks PostGIS while source has it; pg_restore will replay CREATE EXTENSION and will fail unless PostGIS is available."
  elif [[ "$source_postgis" != "none" && "$target_postgis" != "none" && "$source_postgis" != "$target_postgis" ]]; then
    log "PostGIS versions differ; pg_restore supports upgrades but validate spatial functions afterwards."
  fi
}

# Check if the source database is already frozen (default_transaction_read_only = on)
is_source_db_frozen() {
  local ro
  ro=$(psql "$SOURCE_URL" -Atqc "SHOW default_transaction_read_only;" 2>/dev/null || echo "off")
  [[ "$ro" == "on" ]]
}

# Wait until all other sessions on the source database have disconnected
# Controlled by WAIT_SLEEP (poll interval) and WAIT_MAX_ATTEMPTS (0=infinite)
wait_for_sessions_clear() {
  local attempt=0
  while :; do
    attempt=$((attempt + 1))
    local count
    count=$(psql "$SOURCE_URL" -Atqc "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = current_database();")
    if [[ "$count" == "0" ]]; then
      log "Sessions drained."
      return 0
    fi
    log "Waiting for sessions to drain: $count remaining (attempt $attempt)"
    if [[ "$WAIT_MAX_ATTEMPTS" -gt 0 && "$attempt" -ge "$WAIT_MAX_ATTEMPTS" ]]; then
      log "Reached WAIT_MAX_ATTEMPTS with $count sessions still present."
      exit $EXIT_WAIT_TIMEOUT
    fi
    sleep "$WAIT_SLEEP"
  done
}

# Test that a database connection works; exit with error if unreachable
test_connection() {
  local url="$1"
  local label="$2"
  if ! psql "$url" -c "SELECT 1;" >/dev/null 2>&1; then
    log "Connection test failed: $label ($(redact_url "$url"))"
    exit $EXIT_CONN_FAIL
  fi
  log "Connection test passed: $label"
}

# Verify the source database exists (connects to admin db to check)
check_db_exists() {
  local source_admin_url exists
  # Connect to admin db to check if target db exists
  source_admin_url=$(build_url_from_parts "$SOURCE_USER" "$SOURCE_PASS" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_ADMIN_DB" "$SOURCE_SSLMODE")
  exists=$(psql "$source_admin_url" -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" 2>/dev/null || true)
  if [[ "$exists" != "1" ]]; then
    log "Database '$DB_NAME' not found on source ($SOURCE_LABEL)."
    exit $EXIT_DB_MISSING
  fi
  log "Database '$DB_NAME' exists on source ($SOURCE_LABEL)."
}

# Ensure the target database does not already exist; create it if absent
ensure_target_db_created() {
  local admin_url exists
  admin_url=$(build_url_from_parts "$TARGET_USER" "$TARGET_PASS" "$TARGET_HOST" "$TARGET_PORT" "$TARGET_ADMIN_DB" "$TARGET_SSLMODE")
  exists=$(psql "$admin_url" -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" 2>/dev/null || true)
  if [[ "$exists" == "1" ]]; then
    log "Target database already exists: $DB_NAME. Drop it or choose a new target before running."
    exit $EXIT_TARGET_NOT_EMPTY
  fi
  log "Creating target database: $DB_NAME"
  psql "$admin_url" -c "CREATE DATABASE \"$DB_NAME\";" >/dev/null
  log "Target database created: $DB_NAME"
}

# Lock down default permissions on the newly created database (security at inception)
harden_target_db_security() {
  local db_url
  db_url=$(build_url_from_parts "$TARGET_USER" "$TARGET_PASS" "$TARGET_HOST" "$TARGET_PORT" "$DB_NAME" "$TARGET_SSLMODE")
  
  log "Applying security hardening to target database..."
  
  # Revoke public schema creation rights
  if psql "$db_url" -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC;" >/dev/null 2>&1; then
    log "  ✓ Revoked CREATE on schema public from PUBLIC"
  else
    log "  Warning: Failed to revoke CREATE on schema public"
  fi
  
  # Revoke all database privileges from PUBLIC
  if psql "$db_url" -c "REVOKE ALL ON DATABASE \"$DB_NAME\" FROM PUBLIC;" >/dev/null 2>&1; then
    log "  ✓ Revoked all database privileges from PUBLIC"
  else
    log "  Warning: Failed to revoke database privileges from PUBLIC"
  fi
  
  log "Security hardening complete (principle of least privilege applied)"
}

# Ensure the target app role exists (used for ownership/privileges on restore)
ensure_target_role_exists() {
  local admin_url exists member
  admin_url=$(build_url_from_parts "$TARGET_USER" "$TARGET_PASS" "$TARGET_HOST" "$TARGET_PORT" "$TARGET_ADMIN_DB" "$TARGET_SSLMODE")
  exists=$(psql "$admin_url" -Atqc "SELECT 1 FROM pg_roles WHERE rolname = '$TARGET_APP_ROLE';" 2>/dev/null || true)
  if [[ "$exists" == "1" ]]; then
    log "Target role already exists: $TARGET_APP_ROLE"
  else
    log "Creating target role: $TARGET_APP_ROLE with LOGIN capability"
    if psql "$admin_url" -c "CREATE ROLE \"$TARGET_APP_ROLE\" LOGIN PASSWORD '$TARGET_APP_ROLE_PASSWORD';" >/dev/null; then
      log "Target role created: $TARGET_APP_ROLE"
    else
      log "Failed to create target role $TARGET_APP_ROLE; create it manually before retrying."
      exit $EXIT_PRECHECK
    fi
  fi

  # Ensure the connected TARGET_USER can SET ROLE into TARGET_APP_ROLE for pg_restore
  if [[ "$TARGET_APP_ROLE" != "$TARGET_USER" ]]; then
    member=$(psql "$admin_url" -Atqc "
      SELECT 1
      FROM pg_auth_members m
      JOIN pg_roles r ON r.oid = m.roleid
      JOIN pg_roles u ON u.oid = m.member
      WHERE r.rolname = '$TARGET_APP_ROLE' AND u.rolname = '$TARGET_USER';
    " 2>/dev/null || true)
    if [[ "$member" == "1" ]]; then
      log "Target user $TARGET_USER is already a member of $TARGET_APP_ROLE (SET ROLE will work)."
    else
      log "Granting membership: $TARGET_APP_ROLE -> $TARGET_USER so pg_restore can SET ROLE."
      if psql "$admin_url" -c "GRANT \"$TARGET_APP_ROLE\" TO \"$TARGET_USER\";" >/dev/null; then
        log "Granted $TARGET_APP_ROLE to $TARGET_USER."
      else
        log "Failed to grant $TARGET_APP_ROLE to $TARGET_USER; set TARGET_APP_ROLE to a role that $TARGET_USER can SET ROLE to or grant manually."
        exit $EXIT_PRECHECK
      fi
    fi
  fi
  
  # Grant CREATE privilege on the database so the app role can create schemas during restore
  log "Granting CREATE privilege on database $DB_NAME to $TARGET_APP_ROLE"
  local db_url
  db_url=$(build_url_from_parts "$TARGET_USER" "$TARGET_PASS" "$TARGET_HOST" "$TARGET_PORT" "$DB_NAME" "$TARGET_SSLMODE")
  if psql "$db_url" -c "GRANT CREATE ON DATABASE \"$DB_NAME\" TO \"$TARGET_APP_ROLE\";" >/dev/null; then
    log "Granted CREATE privilege on database to $TARGET_APP_ROLE"
  else
    log "Failed to grant CREATE privilege on database; pg_restore may fail when creating schemas."
    exit $EXIT_PRECHECK
  fi
}

# Pre-install PostGIS on the target database if the source uses it
ensure_postgis_on_target() {
  local source_postgis target_postgis db_url
  source_postgis=$(get_postgis_version "$SOURCE_URL")
  
  if [[ "$source_postgis" == "none" ]]; then
    log "Source database does not use PostGIS; skipping PostGIS pre-installation."
    return 0
  fi
  
  log "Source database uses PostGIS $source_postgis"
  db_url=$(build_url_from_parts "$TARGET_USER" "$TARGET_PASS" "$TARGET_HOST" "$TARGET_PORT" "$DB_NAME" "$TARGET_SSLMODE")
  target_postgis=$(get_postgis_version "$db_url")
  
  if [[ "$target_postgis" != "none" ]]; then
    log "PostGIS already installed on target: $target_postgis"
    return 0
  fi
  
  log "Pre-installing PostGIS extension on target database to avoid permission issues..."
  if psql "$db_url" -c "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;" >/dev/null 2>&1; then
    target_postgis=$(get_postgis_version "$db_url")
    log "PostGIS installed on target: $target_postgis"
  else
    log "Failed to install PostGIS on target; ensure PostGIS is available in the target database cluster."
    log "You may need to enable it via control panel or contact support."
    exit $EXIT_PRECHECK
  fi
}

# Drop the target database to allow a clean rerun after a failed restore
drop_target_db() {
  local admin_url exists
  admin_url=$(build_url_from_parts "$TARGET_USER" "$TARGET_PASS" "$TARGET_HOST" "$TARGET_PORT" "$TARGET_ADMIN_DB" "$TARGET_SSLMODE")
  exists=$(psql "$admin_url" -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" 2>/dev/null || true)
  if [[ "$exists" == "1" ]]; then
    log "Dropping target database after failed restore: $DB_NAME"
    # Terminate any active connections before dropping
    psql "$admin_url" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
    if psql "$admin_url" -c "DROP DATABASE \"$DB_NAME\";" >/dev/null; then
      log "Target database dropped: $DB_NAME"
    else
      log "Failed to drop target database $DB_NAME; drop manually before retrying."
    fi
  else
    log "Target database already absent; nothing to drop."
  fi
}

# Run vacuumdb ANALYZE across user objects
analyze_user_tables() {
  log "Running vacuumdb --analyze-only --jobs=$PG_RESTORE_JOBS ..."
  if ! vacuumdb --analyze-only --jobs="$PG_RESTORE_JOBS" --dbname="$TARGET_URL" >/dev/null 2>&1; then
    log "vacuumdb failed; ensure the role owns the restored objects or has sufficient privileges."
    exit $EXIT_VERIFY_FAIL
  fi
}

# Log dump file size and SHA256 checksum for integrity verification
record_dump_integrity() {
  local file="$1"
  local size checksum
  size=$(stat --printf="%s" "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "unknown")
  checksum=$(sha256sum "$file" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$file" 2>/dev/null | awk '{print $1}' || echo "unknown")
  log "Dump file: $file"
  if [[ "$size" =~ ^[0-9]+$ ]]; then
    local mb
    mb=$(awk -v s="$size" 'BEGIN {printf "%.2f", s/1024/1024}')
    log "  Size: ${mb} MB"
  else
    log "  Size: $size"
  fi
  log "  SHA256: $checksum"
}

# Deterministic per-table row counts for parity checking
get_table_row_counts() {
  local schema_filter=""
  [[ -n "$SCHEMA_NAME" ]] && schema_filter="AND schemaname = '$SCHEMA_NAME'"
  
  psql "$1" -Atqc "
    SELECT schemaname || '.' || tablename || '|' || 
           (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, tablename), false, true, '')))[1]::text::bigint AS entry
    FROM pg_tables
    WHERE schemaname NOT IN ('pg_catalog','information_schema')
      $schema_filter
    ORDER BY schemaname, tablename;
  "
}

# Deterministic sequence positions for parity checking
get_sequence_state() {
  local schema_filter=""
  [[ -n "$SCHEMA_NAME" ]] && schema_filter="AND n.nspname = '$SCHEMA_NAME'"
  
  psql "$1" -Atqc "
    SELECT n.nspname || '.' || c.relname || '|' || COALESCE(pg_catalog.pg_sequence_last_value(c.oid)::text, 'NULL')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'S'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      $schema_filter
    ORDER BY n.nspname, c.relname;
  "
}

# Compare two sorted lists; log checksum and small diffs on mismatch
compare_sorted_lists() {
  local label="$1" source_list="$2" target_list="$3" source_file target_file source_hash target_hash
  source_file=$(mktemp)
  target_file=$(mktemp)
  printf '%s\n' "$source_list" >"$source_file"
  printf '%s\n' "$target_list" >"$target_file"
  source_hash=$(sha256sum "$source_file" | awk '{print $1}')
  target_hash=$(sha256sum "$target_file" | awk '{print $1}')
  if [[ "$source_hash" != "$target_hash" ]]; then
    log "$label mismatch detected."
    log "  Source checksum: $source_hash"
    log "  Target checksum: $target_hash"
    log "  Source-only sample:"
    comm -23 "$source_file" "$target_file" | head -n 10 | while IFS= read -r line; do log "    - $line"; done
    log "  Target-only sample:"
    comm -13 "$source_file" "$target_file" | head -n 10 | while IFS= read -r line; do log "    - $line"; done
    rm -f "$source_file" "$target_file"
    return 1
  fi
  rm -f "$source_file" "$target_file"
  log "  $label match."
  return 0
}

verify_basic_parity() {
  log "Verifying deterministic parity (row counts + sequences)..."
  local source_rows target_rows source_seq target_seq source_total target_total
  source_rows=$(get_table_row_counts "$SOURCE_URL")
  target_rows=$(get_table_row_counts "$TARGET_URL")
  
  # Calculate total row counts
  source_total=$(echo "$source_rows" | awk -F'|' '{sum += $2} END {print sum+0}')
  target_total=$(echo "$target_rows" | awk -F'|' '{sum += $2} END {print sum+0}')
  
  # Format with thousands separators
  source_total_fmt=$(printf "%'d" "$source_total" 2>/dev/null || echo "$source_total")
  target_total_fmt=$(printf "%'d" "$target_total" 2>/dev/null || echo "$target_total")
  
  log "  $SOURCE_LABEL total rows: $source_total_fmt"
  log "  $TARGET_LABEL total rows: $target_total_fmt"
  
  if ! compare_sorted_lists "Row counts" "$source_rows" "$target_rows"; then
    exit $EXIT_VERIFY_FAIL
  fi

  # Sequences are auto-increment counters (e.g., for id columns); verify they're at the same position
  source_seq=$(get_sequence_state "$SOURCE_URL")
  target_seq=$(get_sequence_state "$TARGET_URL")
  
  # Count sequences and log a few examples
  source_seq_count=$(echo "$source_seq" | grep -c '|' || echo "0")
  target_seq_count=$(echo "$target_seq" | grep -c '|' || echo "0")
  
  log "  $SOURCE_LABEL sequences: $source_seq_count"
  log "  $TARGET_LABEL sequences: $target_seq_count"
  
  if [[ "$source_seq_count" -gt 0 ]]; then
    log "  Sample sequence positions (first 3):"
    echo "$source_seq" | head -n 3 | while IFS='|' read -r name val; do
      log "    $name: $val"
    done
  fi
  
  if ! compare_sorted_lists "Sequence positions" "$source_seq" "$target_seq"; then
    exit $EXIT_VERIFY_FAIL
  fi
}

# Print explicit rollback steps if migration fails or needs reverting
print_rollback_guidance() {
  local renamed_db="${1:-${DB_NAME}_migrated_TIMESTAMP}"
  log ""
  log "=== ROLLBACK GUIDANCE ==="
  log "If you need to rollback, run these SQL commands:"
  log ""
  
  if [[ "$renamed_db" != "$DB_NAME" ]]; then
    # Database was renamed - show unfreeze and rename back
    log "1. On source ($SOURCE_LABEL) - unfreeze and rename back:"
    log "   ALTER DATABASE \"$renamed_db\" RESET default_transaction_read_only;"
    log "   ALTER DATABASE \"$renamed_db\" RENAME TO \"$DB_NAME\";"
    log ""
    log "2. On target ($TARGET_LABEL) - drop the migrated database:"
    log "   DROP DATABASE \"$DB_NAME\";"
    log ""
  else
    # Database was not renamed - only show unfreeze
    log "1. On source ($SOURCE_LABEL) - unfreeze database:"
    log "   ALTER DATABASE \"$DB_NAME\" RESET default_transaction_read_only;"
    log ""
    log "2. On target ($TARGET_LABEL) - drop the migrated database:"
    log "   DROP DATABASE \"$DB_NAME\";"
    log ""
  fi
  
  log "3. Point app back to source and re-run this script after fixing any issues."
  log "========================="
}

# Warn user if script exits while source is frozen
cleanup() {
  local status=$?
  if [[ "$FROZEN" -eq 1 ]]; then
    local frozen_db="${FROZEN_DB_NAME:-$DB_NAME}"
    echo "" >&2
    echo "=== WARNING: Source database ($SOURCE_LABEL) is still in READ-ONLY mode ===" >&2
    echo "The script exited while source was frozen. To unfreeze, run this SQL on $SOURCE_LABEL:" >&2
    echo "  ALTER DATABASE \"$frozen_db\" RESET default_transaction_read_only;" >&2
    echo "=========================================================" >&2
  fi
  return $status
}

trap cleanup EXIT

# --- Main ---

SCRIPT_START_TIME=$(date +%s)

parse_args "$@"

if [[ -z "$CONFIG_FILE" ]]; then
  log "A --config .env file is required"
  log "Use --help for usage"
  exit $EXIT_MISSING_VARS
fi

if [[ -z "$DIRECTION" ]]; then
  log "Missing required --direction parameter (pi-to-do or do-to-pi)"
  log "Use --help for usage"
  exit $EXIT_MISSING_VARS
fi

# Set labels based on direction and validate all required variables
parse_direction

# Set up file naming with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create history directory structure for this migration run
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HISTORY_BASE="${SCRIPT_DIR}/history"
RUN_FOLDER="${DIRECTION}_migration_${DB_NAME}_${SCHEMA_NAME}_${TIMESTAMP}"
RUN_DIR="${HISTORY_BASE}/${RUN_FOLDER}"

# Create the run directory if it doesn't exist
mkdir -p "$RUN_DIR"

DUMP_FILE="${RUN_DIR}/dump.pg"
if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="${RUN_DIR}/log.txt"
fi

log "=== $SOURCE_LABEL → $TARGET_LABEL Migration ==="
log "History directory: $RUN_DIR"
log "Log file: $LOG_FILE"

# Build URLs from SOURCE/TARGET parts
SOURCE_URL=$(build_url_from_parts "$SOURCE_USER" "$SOURCE_PASS" "$SOURCE_HOST" "$SOURCE_PORT" "$DB_NAME" "$SOURCE_SSLMODE")
TARGET_URL=$(build_url_from_parts "$TARGET_USER" "$TARGET_PASS" "$TARGET_HOST" "$TARGET_PORT" "$DB_NAME" "$TARGET_SSLMODE")
log "Built connection URLs from parts."

step_start "[1/11] Preflight checks"
require_cmd psql
require_cmd vacuumdb
require_cmd python3
check_client_versions_against_target
step_end

log "Target DB name: $DB_NAME"
log "Schema filter: $SCHEMA_NAME"
log "Source ($SOURCE_LABEL): $(redact_url "$SOURCE_URL")"
log "Target ($TARGET_LABEL): $(redact_url "$TARGET_URL")"
log "Dump file: $DUMP_FILE"
log "Direction: $DIRECTION"

read -r -p "Proceed with migration? [y/N] " ans
if [[ ! "$ans" =~ ^[Yy]$ ]]; then
  log "Aborted by user (no changes)."
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
  fi
  exit 0
fi

step_start "[2/11] Check source database exists"
check_db_exists
check_for_old_migrations

# Verify schema exists in source database
schema_exists=$(psql "$SOURCE_URL" -Atqc "SELECT 1 FROM information_schema.schemata WHERE schema_name = '$SCHEMA_NAME';" 2>/dev/null || true)
if [[ "$schema_exists" != "1" ]]; then
  log "Schema '$SCHEMA_NAME' not found in source database '$DB_NAME' on $SOURCE_LABEL."
  exit $EXIT_DB_MISSING
fi
log "Schema '$SCHEMA_NAME' exists in source database."
step_end

step_start "[3/11] Connection tests + target prep"
ensure_target_db_created
harden_target_db_security
ensure_target_role_exists
ensure_postgis_on_target
test_connection "$SOURCE_URL" "Source ($SOURCE_LABEL)"
test_connection "$TARGET_URL" "Target ($TARGET_LABEL)"
step_end

step_start "[4/11] Compatibility checks (versions)"
check_versions
step_end

log ""
log "=== PRE-FREEZE REMINDER ==="
log "Before proceeding, ensure:"
log "  1. App is in maintenance mode or stopped"
log "  2. Cron jobs writing to $DB_NAME are disabled"
log "  3. Background workers are stopped"
log "==========================="
log ""
read -r -p "Ready to freeze source database ($SOURCE_LABEL)? [y/N] " ans
if [[ ! "$ans" =~ ^[Yy]$ ]]; then
  log "Aborted before freeze (no changes)."
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
  fi
  exit 0
fi

step_start "[5/11] Freeze writes on source ($SOURCE_LABEL) (read-only)"
if is_source_db_frozen; then
  log "Source database is already read-only; skipping freeze."
  FROZEN=1
  FROZEN_DB_NAME="$DB_NAME"
else
  psql "$SOURCE_URL" -c "ALTER DATABASE \"$DB_NAME\" SET default_transaction_read_only = on;"
  FROZEN=1
  FROZEN_DB_NAME="$DB_NAME"
fi
step_end

step_start "[6/11] Wait for sessions to drain"
wait_for_sessions_clear
step_end

step_start "[7/11] Dump from source ($SOURCE_LABEL) to $DUMP_FILE (compressed)"
# Build pg_dump command
dump_cmd=("$PG_DUMP_BIN" -Fc -Z9 -d "$SOURCE_URL" -f "$DUMP_FILE")

# Dump only the specified schema
log "Dumping only schema: $SCHEMA_NAME"
dump_cmd+=(--schema "$SCHEMA_NAME")

set +e
"${dump_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
dump_status=${PIPESTATUS[0]}
set -e
if [[ "$dump_status" -ne 0 ]]; then
  log "pg_dump failed with status $dump_status"
  exit $EXIT_DUMP_FAIL
fi
# Verify dump file was created and is non-empty
if [[ ! -s "$DUMP_FILE" ]]; then
  log "Dump file is empty or missing: $DUMP_FILE"
  exit $EXIT_DUMP_FAIL
fi
record_dump_integrity "$DUMP_FILE"
step_end

step_start "[8/11] Restore into target ($TARGET_LABEL)"
log "pg_restore running with --jobs=$PG_RESTORE_JOBS"
set +e
"$PG_RESTORE_BIN" -Fc -j "$PG_RESTORE_JOBS" --role "$TARGET_APP_ROLE" --no-owner -d "$TARGET_URL" "$DUMP_FILE" 2>&1 | tee -a "$LOG_FILE"
restore_status=${PIPESTATUS[0]}
set -e
if [[ "$restore_status" -ne 0 ]]; then
  log "pg_restore exited with status $restore_status (warnings are common; check log for errors)"
  drop_target_db
  exit $EXIT_RESTORE_FAIL
fi
step_end

step_start "[9/11] ANALYZE on target ($TARGET_LABEL)"
analyze_user_tables
step_end

step_start "[10/11] Verify target ($TARGET_LABEL) (temp write, row counts, sequences)"
# Basic write test
psql "$TARGET_URL" -c "CREATE TEMP TABLE __migrate_check(x int); INSERT INTO __migrate_check VALUES (1); DROP TABLE __migrate_check;" >/dev/null
# PostGIS check (only if extension exists)
if psql "$TARGET_URL" -Atqc "SELECT 1 FROM pg_extension WHERE extname = 'postgis';" | grep -q 1; then
  psql "$TARGET_URL" -c "SELECT PostGIS_Version();" >/dev/null && log "  PostGIS verified."
fi
verify_basic_parity
step_end

step_start "[11/11] Post-migration cleanup"
if [[ "$RENAME_SOURCE" == "true" ]]; then
  log "Renaming source database (keeping it frozen for safety)..."
  source_admin_url=$(build_url_from_parts "$SOURCE_USER" "$SOURCE_PASS" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_ADMIN_DB" "$SOURCE_SSLMODE")

  RENAME_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  renamed_name="${DB_NAME}_migrated_${RENAME_TIMESTAMP}"
  actual_frozen_db="$DB_NAME"
  renamed_exists=$(psql "$source_admin_url" -Atqc "SELECT 1 FROM pg_database WHERE datname = '$renamed_name';" 2>/dev/null || true)
  if [[ "$renamed_exists" == "1" ]]; then
    log "  Warning: Database $renamed_name already exists on source; skipping rename"
    log "  Original database $DB_NAME remains frozen; unfreeze manually if needed"
    actual_frozen_db="$DB_NAME"
  else
    # Terminate any active connections to the database before renaming
    psql "$source_admin_url" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
    if psql "$source_admin_url" -c "ALTER DATABASE \"$DB_NAME\" RENAME TO \"$renamed_name\";" >/dev/null; then
      log "  Source database renamed: $DB_NAME → $renamed_name"
      log "  Database remains in read-only mode as a frozen snapshot"
      actual_frozen_db="$renamed_name"
      # Rename successful; clear FROZEN flag since DB is now under a different name
      FROZEN=0
    else
      log "  Warning: Failed to rename source database; manual rename required"
      log "  Database $DB_NAME remains frozen under original name"
      actual_frozen_db="$DB_NAME"
    fi
  fi
else
  log "Skipping source database rename (--rename-source=false)"
  log "Source database remains as: $DB_NAME (frozen in read-only mode)"
  log "WARNING: You must manually rename or unfreeze before reusing this database name"
  actual_frozen_db="$DB_NAME"
fi
step_end

TOTAL_ELAPSED=$(($(date +%s) - SCRIPT_START_TIME))
log ""
log "=== Migration complete in ${TOTAL_ELAPSED}s ==="
log "Target ($TARGET_LABEL) database available as: $DB_NAME"
if [[ "$RENAME_SOURCE" == "false" ]]; then
  log "Source ($SOURCE_LABEL) database kept as: $DB_NAME (frozen in read-only mode)"
  log "WARNING: Source database name unchanged - manually rename or unfreeze as needed"
  log ""
  log "To manually rename the source database later, run these SQL commands on $SOURCE_LABEL:"
  MANUAL_RENAME_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  manual_renamed_name="${DB_NAME}_migrated_${MANUAL_RENAME_TIMESTAMP}"
  log "  SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();"
  log "  ALTER DATABASE \"$DB_NAME\" RENAME TO \"$manual_renamed_name\";"
  log ""
elif [[ "$actual_frozen_db" == "$DB_NAME" ]]; then
  log "WARNING: Source ($SOURCE_LABEL) database rename was skipped or failed!"
  log "Source database: $actual_frozen_db (still frozen under original name)"
  log "You must manually rename or unfreeze before running applications."
else
  log "Source ($SOURCE_LABEL) database renamed to: $actual_frozen_db (read-only)"
fi
log "Update app connection string to point to $DB_NAME on $TARGET_LABEL and validate"
log "Log saved to: $LOG_FILE"

print_rollback_guidance "$actual_frozen_db"
