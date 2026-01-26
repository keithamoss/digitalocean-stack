# PostgreSQL 15 + PostGIS + pgBackRest for S3 backups
FROM ghcr.io/baosystems/postgis:15-3.3

# Install pgBackRest and setup directories
# Note: /var/lib/pgbackrest and /var/log/pgbackrest auto-created with correct ownership
RUN apt-get update && \
  apt-get install -y --no-install-recommends pgbackrest && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Create spool directory for pgBackRest (used for lock files and async operations)
RUN mkdir -p /tmp/pgbackrest && \
  chown postgres:postgres /tmp/pgbackrest

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
