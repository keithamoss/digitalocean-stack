#!/bin/bash

# git pull origin master
docker compose -f ../db/compose.yml pull
docker compose -f ../db/compose.yml stop
docker compose -f ../db/compose.yml up --remove-orphans -d

docker image prune --force