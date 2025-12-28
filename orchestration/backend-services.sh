#!/bin/bash

# git pull origin master
docker compose -f ../db/db-production.yml pull
docker compose -f ../db/db-production.yml stop
docker compose -f ../db/db-production.yml up --remove-orphans -d

docker image prune --force