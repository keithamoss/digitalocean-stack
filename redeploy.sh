#!/bin/bash

git pull origin master
docker-compose -f docker-compose-prod.yml pull
docker-compose -f docker-compose-prod.yml stop
docker-compose -f docker-compose-prod.yml up -d