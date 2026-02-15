#!/bin/bash

# git pull origin master
# Build image locally (not published to Docker Hub)
docker compose -f ../db/compose.yml build
docker compose -f ../db/compose.yml stop

# Ensure log directories exist with correct ownership for postgres (UID 999)
sudo mkdir -p ../logs/db/postgresql ../logs/db/pgbackrest
sudo chown -R 999:999 ../logs/db/postgresql ../logs/db/pgbackrest
# 705 = rwx---r-x: Owner (postgres) has full access, others can read logs without sudo
sudo chmod 705 ../logs/db/postgresql

docker compose -f ../db/compose.yml up --remove-orphans -d

docker image prune --force