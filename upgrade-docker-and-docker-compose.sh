#!/bin/bash

# Stop the docker containers first!
# Docker version 17.12.0-ce, build c97c6d6
apt-get update
apt-get upgrade docker-ce

# https://stackoverflow.com/a/51435214/7368493
compose_version=$(curl https://api.github.com/repos/docker/compose/releases/latest | jq .name -r)
output='/usr/local/bin/docker-compose'
curl -L https://github.com/docker/compose/releases/download/$compose_version/docker-compose-$(uname -s)-$(uname -m) -o $output
chmod +x $output
echo $(docker-compose --version)