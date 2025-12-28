#!/bin/bash

# git pull origin master
docker compose -f ../infra/pi/pi-hosting/cloudflared.yml pull
docker compose -f ../infra/pi/pi-hosting/cloudflared.yml stop
docker compose -f ../infra/pi/pi-hosting/cloudflared.yml up --remove-orphans -d

docker image prune --force