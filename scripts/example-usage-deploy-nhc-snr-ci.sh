#!/bin/bash

# This will deploy latest NHC + SNR pushed by upstream CI into the given namespace

NAME=build-nhc-snr.sh
if [ ! -f ${NAME} ]; then
  # get script from github
  REPO=${REPO:-medik8s/tools}
  BRANCH=${BRANCH:-main}
  curl https://raw.githubusercontent.com/${REPO}/${BRANCH}/scripts/${NAME} -o $NAME
  chmod +x $NAME
fi

# set some vars
export DEPLOY_NAMESPACE=my-test
export INDEX_VERSION=9.9.9-ci

# do not build, just deploy
./$NAME --skip-build
