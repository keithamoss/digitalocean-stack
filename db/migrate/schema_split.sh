#!/bin/bash

# Schema Split Script
# 
# This script extracts a specific schema from a source PostgreSQL database and creates
# a new dedicated database with that schema.
#
# Usage:
#   ./schema_split.sh <BASE_SOURCE_CONN> <BASE_TARGET_CONN>
#
# Parameters:
#   BASE_SOURCE_CONN  - Base PostgreSQL connection string (without database name)
#   BASE_TARGET_CONN  - Base PostgreSQL connection string (without database name)
#
# Examples:
#   # Local to local migration
#   ./schema_split.sh "postgresql://postgres:pass@127.0.0.1:5432" "postgresql://postgres:pass@127.0.0.1:5432"
#
#   # Remote to local migration
#   ./schema_split.sh "postgresql://user:pass@remote.example.com:5432" "postgresql://postgres:pass@127.0.0.1:5432"

# Parse command line arguments
if [ "$#" -ne 2 ]; then
    echo "Error: Incorrect number of arguments"
    echo "Usage: $0 <BASE_SOURCE_CONN> <BASE_TARGET_CONN>"
    exit 1
fi

BASE_SOURCE_CONN="$1"
BASE_TARGET_CONN="$2"

# Configuration variables
PG_BIN_PATH="/usr/lib/postgresql/15/bin"
SOURCE_DB_NAME="staging"
SCHEMA_NAME="mapa"
TARGET_DB="mapa_staging"
ROLE_NAME="app_mapa_staging"
ROLE_PASSWORD="strong-password"

# Build connection strings by appending database names
SOURCE_CONN_STRING="${BASE_SOURCE_CONN}/${SOURCE_DB_NAME}"
TARGET_CONN_STRING="${BASE_TARGET_CONN}/${TARGET_DB}"
DUMP_FILE="${SCHEMA_NAME}_${SOURCE_DB_NAME}.dump"

# Dump the specific schema from the source database
"${PG_BIN_PATH}/pg_dump" -d "${SOURCE_CONN_STRING}" --schema "${SCHEMA_NAME}" -Fc -f "${DUMP_FILE}"

# "${PG_BIN_PATH}/psql" -d "${SOURCE_CONN_STRING}" -c "DROP DATABASE ${TARGET_DB};"

# Create the new database
"${PG_BIN_PATH}/psql" -d "${SOURCE_CONN_STRING}" -c "CREATE DATABASE ${TARGET_DB};"

# Create the PostGIS extension in the new database
"${PG_BIN_PATH}/psql" -d "${TARGET_CONN_STRING}" -c "CREATE EXTENSION postgis;"

# Create a new role for the target database
"${PG_BIN_PATH}/psql" -d "${SOURCE_CONN_STRING}" -c "CREATE ROLE ${ROLE_NAME} LOGIN PASSWORD '${ROLE_PASSWORD}';"

# Grant CREATE privilege on the new database to the role
"${PG_BIN_PATH}/psql" -d "${TARGET_CONN_STRING}" -c "GRANT CREATE ON DATABASE ${TARGET_DB} TO ${ROLE_NAME};"

# Restore the dumped schema into the new database
"${PG_BIN_PATH}/pg_restore" -d "${TARGET_CONN_STRING}" --role "${ROLE_NAME}" --no-owner "${DUMP_FILE}"

# Perform VACUUM ANALYZE on the new database to optimise performance
"${PG_BIN_PATH}/psql" -d "${TARGET_CONN_STRING}" -c "VACUUM ANALYZE;"