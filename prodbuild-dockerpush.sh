#!/bin/bash

# push images to Docker Hub
# @TODO version images

if [ ! -f ./VERSION ]; then
    echo "File not found!"
    exit 1
fi

VERSION=`cat VERSION`

if [ x"$VERSION" = x ]; then
        echo "set a version!"
        exit 1
fi

echo pushing prod nginx container
docker tag sausage/nginx:latest keithmoss/sausage-nginx:latest
docker tag sausage/nginx:latest keithmoss/sausage-nginx:"$VERSION"
docker push keithmoss/sausage-nginx:latest
docker push keithmoss/sausage-nginx:"$VERSION"