#!/bin/bash

# get script from github
REPO=${REPO:-medik8s/tools}
BRANCH=${BRANCH:-main}
NAME=build-nhc-snr.sh
curl https://raw.githubusercontent.com/${REPO}/${BRANCH}/scripts/${NAME} -o $NAME
chmod +x $NAME

# set some vars
export IMAGE_REGISTRY=quay.io/medik8s
export NHC_VERSION=0.3.0-example
export SNR_VERSION=0.4.0-example
export INDEX_VERSION=4.11-example

# build and push images
./$NAME --skip-deploy
