#!/bin/bash
# Wrapper for pgBackRest that loads AWS credentials
set -e

# Load AWS credentials from Docker secret
if [ -f /run/secrets/aws.env ]; then
    export $(grep -v '^#' /run/secrets/aws.env | grep '=' | xargs)
    export PGBACKREST_REPO1_S3_KEY="$AWS_ACCESS_KEY_ID"
    export PGBACKREST_REPO1_S3_KEY_SECRET="$AWS_SECRET_ACCESS_KEY"
else
    echo "ERROR: AWS credentials file not found at /run/secrets/aws.env" >&2
    exit 1
fi

# Verify credentials were loaded
if [ -z "$PGBACKREST_REPO1_S3_KEY" ] || [ -z "$PGBACKREST_REPO1_S3_KEY_SECRET" ]; then
    echo "ERROR: AWS credentials not loaded properly" >&2
    exit 1
fi

# Execute pgbackrest with all arguments
exec /usr/bin/pgbackrest "$@"
