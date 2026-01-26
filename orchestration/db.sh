#!/bin/bash

# git pull origin master
# Build image locally (not published to Docker Hub)
docker compose -f ../db/compose.yml build
docker compose -f ../db/compose.yml stop

# Ensure log directories exist with correct ownership for postgres (UID 999)
sudo mkdir -p ../db/logs/postgresql ../db/logs/pgbackrest
sudo chown -R 999:999 ../db/logs/postgresql ../db/logs/pgbackrest
sudo chmod 700 ../db/logs/postgresql

docker compose -f ../db/compose.yml up --remove-orphans -d

docker image prune --force