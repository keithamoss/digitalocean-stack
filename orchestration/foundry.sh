#!/bin/bash

# git pull origin master

# v13 container runs as uid:gid 1000:1000; ensure the data dir matches (see https://github.com/felddy/foundryvtt-docker/discussions/1197).
echo "Ensuring foundry data dir ownership..."
DATA_DIR="../foundry/data"
if [ ! -d "$DATA_DIR" ]; then
  echo "Creating $DATA_DIR ..."
  mkdir -p "$DATA_DIR"
fi
sudo chown -R 1000:1000 "$DATA_DIR"
echo

echo "Pulling latest images for foundry..."
docker compose -f ../foundry/compose.yml pull
echo

echo "Stopping existing containers..."
docker compose -f ../foundry/compose.yml stop
echo

echo "Starting updated containers (removing orphans)..."
docker compose -f ../foundry/compose.yml up --remove-orphans -d
echo

echo "Pruning unused Docker images..."
docker image prune --force
echo