#!/bin/bash

git pull origin master
docker-compose -f docker-compose.yml pull
docker-compose -f docker-compose.yml stop
docker-compose -f docker-compose.yml up -d