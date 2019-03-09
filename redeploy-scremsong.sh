#!/bin/bash

git pull origin master
docker-compose -f docker-compose-prod-scremsong.yml pull
docker-compose -f docker-compose-prod-scremsong.yml stop
docker-compose -f docker-compose-prod-scremsong.yml up --remove-orphans -d

export $(xargs < secrets/travis.env)
curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache" -H "X-Auth-Email:$CF_EMAIL" -H "X-Auth-Key:$CF_API_KEY" -H "Content-Type:application/json" --data '{"purge_everything":true}'