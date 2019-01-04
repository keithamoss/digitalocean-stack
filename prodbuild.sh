#!/bin/bash

# DEMSAUSAGE_VERSION=""
# DEMSAUSAGE_ADMIN_VERSION=""
SCREMSONG_VERSION="2.1.0"

\rm -f nginx/build/*.tgz
mkdir -p nginx/build/scremsong
mkdir -p nginx/build/demsausage
mkdir -p nginx/build/demsausage-admin

# build production nginx image
# assumes local sources exist for DemocracySausage and Scremsong
# this is horrible, fixme
cp ../scremsong/build/frontend-"$SCREMSONG_VERSION".tgz ../scremsong/build/django-"$SCREMSONG_VERSION".tgz nginx/build/scremsong
# cp ../demsausage-v3/build/frontend-public-"$DEMSAUSAGE_VERSION".tgz nginx/build/demsausage
# cp ../demsausage-v3/build/frontend-admin-"$DEMSAUSAGE_ADMIN_VERSION".tgz nginx/build/demsausage-admin

echo building prod nginx container
(cd nginx && docker build -t sausage/nginx:latest .)
# (cd nginx-prod && docker build --no-cache -t sausage/nginx:latest . && cd ..)