#!/bin/bash

# git pull origin master
docker compose -f ../demsausage/staging.yml pull
docker compose -f ../demsausage/staging.yml stop
docker compose -f ../demsausage/staging.yml up --remove-orphans -d

docker image prune --force