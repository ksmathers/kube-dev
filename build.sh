#!/bin/bash
. setting.sh
export DOCKER_DEFAULT_PLATFORM=linux/amd64
docker build -t ${APPNAME}:${VERSION} .
docker tag ${APPNAME}:${VERSION} ${APPNAME}:latest