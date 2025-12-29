#!/bin/bash

# git pull origin master
docker compose -f ../redis/compose.yml pull
docker compose -f ../redis/compose.yml stop
docker compose -f ../redis/compose.yml up --remove-orphans -d

docker image prune --force