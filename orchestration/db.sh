#!/bin/bash

# Must NOT be run as root: $(whoami) is used to identify the deploy user for ACL
# grants on the pgbackrest log directory. Running as root would grant ACL access to
# root itself, not to the actual user who needs to read the logs without sudo.
# Use sudo internally (as this script does) rather than running the script as root.
if [ "$EUID" -eq 0 ]; then
    echo "[ERROR] Do not run this script as root. Run as your normal deploy user; sudo is used internally where needed." >&2
    exit 1
fi

STACK_USER=$(whoami)

# git pull origin master
# Build image locally (not published to Docker Hub)
docker compose -f ../db/compose.yml build
docker compose -f ../db/compose.yml stop

# Ensure log directories exist with correct ownership for postgres (UID 999)
sudo mkdir -p ../logs/db/postgresql ../logs/db/pgbackrest ../logs/db/pgbackrest/archive
sudo chown -R 999:999 ../logs/db/postgresql ../logs/db/pgbackrest
# 705 = rwx---r-x: Owner (postgres) has full access, others can read logs without sudo
sudo chmod 705 ../logs/db/postgresql

# Grant the deploy user full access (read, write, delete) to pgbackrest logs via ACL.
# pgbackrest hardcodes log file mode to 0640 (root:root when run via docker exec),
# so the ACL is the only access path for the deploy user.
# setup.sh sets initial ACLs on the whole logs/ tree; we re-apply here because
# the chown above changes ownership of these dirs on every redeploy.
# Capital X: sets execute on directories but not regular files.
sudo setfacl -R -m u:"$STACK_USER":rwX ../logs/db/pgbackrest
sudo setfacl -d -m u:"$STACK_USER":rwx ../logs/db/pgbackrest
sudo setfacl -d -m u:"$STACK_USER":rwx ../logs/db/pgbackrest/archive

docker compose -f ../db/compose.yml up --remove-orphans -d

docker image prune --force