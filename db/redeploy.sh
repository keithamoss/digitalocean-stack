#!/bin/bash

git pull origin master
docker compose -f db-production.yml pull
docker compose -f db-production.yml stop
docker compose -f db-production.yml up --remove-orphans -d