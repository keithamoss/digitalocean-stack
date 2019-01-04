#!/bin/bash

# push images to Docker Hub
# @TODO version images

ver="$1"

if [ x"$ver" = x ]; then
        echo "set a version!"
        exit 1
fi

echo pushing prod nginx container
docker tag sausage/nginx:latest keithmoss/sausage-nginx:latest
docker tag sausage/nginx:latest keithmoss/sausage-nginx:"$ver"
docker push keithmoss/sausage-nginx:latest
docker push keithmoss/sausage-nginx:"$ver"