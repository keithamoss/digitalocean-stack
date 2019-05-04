#!/bin/bash

DEMSAUSAGE_VERSION_FILE="../demsausage/VERSION"
if [ ! -f "$DEMSAUSAGE_VERSION_FILE" ]; then
    echo "DemSausage version file not found!"
    exit 1
fi

DEMSAUSAGE_VERSION=`cat $DEMSAUSAGE_VERSION_FILE`
PUSH="$1"

DEMSAUSAGE_VERSION="$DEMSAUSAGE_VERSION"
DEMSAUSAGE_ADMIN_VERSION="$DEMSAUSAGE_VERSION"
DEMSAUSAGE_DJANGO_VERSION="$DEMSAUSAGE_VERSION"
SCREMSONG_VERSION="2.1.15"
SCREMSONG_DJANGO_VERSION="2.1.15"

\rm -f nginx/build/*/*.tgz
mkdir -p nginx/build/scremsong
mkdir -p nginx/build/scremsong-api
mkdir -p nginx/build/demsausage
mkdir -p nginx/build/demsausage-admin
mkdir -p nginx/build/demsausage-api

# build production nginx image
# assumes local sources exist for DemocracySausage and Scremsong
# this is horrible, fixme
cp ../scremsong/build/frontend-"$SCREMSONG_VERSION".tgz ../scremsong/build/django-"$SCREMSONG_VERSION".tgz nginx/build/scremsong
cp ../scremsong/build/django-"$SCREMSONG_DJANGO_VERSION".tgz nginx/build/scremsong-api
cp ../demsausage/build/frontend-public-"$DEMSAUSAGE_VERSION".tgz nginx/build/demsausage
cp ../demsausage/build/frontend-admin-"$DEMSAUSAGE_ADMIN_VERSION".tgz nginx/build/demsausage-admin
cp ../demsausage/build/django-"$DEMSAUSAGE_DJANGO_VERSION".tgz nginx/build/demsausage-api

echo building prod nginx container
(cd nginx && docker build -t sausage/nginx:latest .)
# (cd nginx-prod && docker build --no-cache -t sausage/nginx:latest . && cd ..)

if [ "$PUSH" = "push" ]; then
    ./prodbuild-dockerpush.sh
fi