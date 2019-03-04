#!/bin/bash

DEMSAUSAGE_VERSION="0.2.2"
DEMSAUSAGE_ADMIN_VERSION="0.2.2"
DEMSAUSAGE_DJANGO_VERSION="0.2.2"
SCREMSONG_VERSION="2.1.6"
SCREMSONG_DJANGO_VERSION="2.1.6"

\rm -f nginx/build/*.tgz
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