#!/bin/bash

# git pull origin master
echo "Pulling latest images for demsausage staging..."
docker compose -f ../demsausage/staging.yml pull
echo

echo "Stopping existing containers..."
docker compose -f ../demsausage/staging.yml stop
echo

echo "Starting updated containers (removing orphans)..."
docker compose -f ../demsausage/staging.yml up --remove-orphans -d
echo

echo "Pruning unused Docker images..."
docker image prune --force
echo

echo "Loading Cloudflare credentials and purging cache..."
export $(xargs < ./secrets/cloudflare.env)
curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache" -H "X-Auth-Email:$CF_EMAIL" -H "X-Auth-Key:$CF_API_KEY" -H "Content-Type:application/json" --data '{"purge_everything":true}'