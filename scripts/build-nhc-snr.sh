#!/bin/bash

set -e

export IMAGE_REGISTRY=${IMAGE_REGISTRY:-quay.io/medik8s}

# Version for the index image
export INDEX_VERSION=${INDEX_VERSION:-0.0.1-test}
# remove leading "v"
INDEX_VERSION=${INDEX_VERSION//v/}

export NHC_VERSION=${NHC_VERSION:-0.0.1-test}
NHC_VERSION=${NHC_VERSION//v/}

export SNR_VERSION=${SNR_VERSION:-0.0.1-test}
SNR_VERSION=${SNR_VERSION//v/}

NHC_GIT_REPO=${NHC_GIT_REPO:-https://github.com/medik8s/node-healthcheck-operator.git}
NHC_GIT_BRANCH=${NHC_GIT_BRANCH:-main}

SNR_GIT_REPO=${SNR_GIT_REPO:-https://github.com/medik8s/self-node-remediation.git}
SNR_GIT_BRANCH=${SNR_GIT_BRANCH:-main}

usage() {
	echo "This script will pull sources of NHC and SNR and build and push all images need for deployment."
	echo "Finally it will create a CatalogSource, and a Subscription in the openshift-operators namespace to install NHC/SNR."
	echo "Supported options:"
	echo "--skip-nhc: skip building NHC, use last built images"
	echo "--skip-snr: skip building SNR, use last built images"
	echo "--skip-build: skip building NHC, SNR and index images, use last built images"
	echo "--skip-deploy: skip deployment"
	echo "--help | -h: print usage"
}

BUILD_NHC=true
BUILD_SNR=true
BUILD_INDEX=true
DEPLOY=true

while [[ $# -gt 0 ]]; do
	case $1 in
	--skip-nhc)
		BUILD_NHC=false
		shift
		;;
	--skip-snr)
		BUILD_SNR=false
		shift
		;;
	--skip-build)
		BUILD_NHC=false
		BUILD_SNR=false
		BUILD_INDEX=false
		shift
		;;
	--skip-deploy)
		DEPLOY=false
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Unknown option $1"
		usage
		exit 1
		;;
	esac
done

set -x

# Ensure needed binaries are installed
which git 2>/dev/null || (
	echo "please install git"
	exit 1
)
which docker 2>/dev/null || (
	echo "please install docker"
	exit 1
)
which make 2>/dev/null || (
	echo "please install make"
	exit 1
)

OPM_BIN=""

if [ "$BUILD_NHC" = true ]; then
	# Get NHC and build images and push images
	NHC_DIR=nhc-tmp
	sudo rm -rf $NHC_DIR
	mkdir -p $NHC_DIR
	pushd $NHC_DIR
	git clone --depth 1 -b $NHC_GIT_BRANCH $NHC_GIT_REPO .
	export VERSION=$NHC_VERSION && make container-build container-push

	# downlaod opm tool for later
	make opm
	OPM_BIN=./${NHC_DIR}/bin/opm
	popd
else
	# without NHC we need opm on the PATH
	which opm 2>/dev/null || (
		echo "please install opm, or don't skip NHC build"
		exit 1
	)
	OPM_BIN=`which opm`
fi

if [ "$BUILD_SNR" = true ]; then
	# Get SNR and build images and push images
	SNR_DIR=snr-tmp
	sudo rm -rf $SNR_DIR
	mkdir -p $SNR_DIR
	pushd $SNR_DIR
	git clone --depth 1 -b $SNR_GIT_BRANCH $SNR_GIT_REPO .
	export VERSION=$SNR_VERSION && make container-build container-push
	popd
fi

export INDEX_IMG=${IMAGE_REGISTRY}/nhc-snr-index:v${INDEX_VERSION}
if [ "$BUILD_INDEX" = true ]; then
	# Build index image
	$OPM_BIN index add --build-tool docker --mode semver --tag $INDEX_IMG --bundles ${IMAGE_REGISTRY}/node-healthcheck-operator-bundle:v${NHC_VERSION},${IMAGE_REGISTRY}/self-node-remediation-operator-bundle:v${SNR_VERSION}
	docker push $INDEX_IMG
fi

if [ "$DEPLOY" = true ]; then

    # create CatalogSource and Subscription
    cat > cs.yaml <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: medik8s-upstream
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $INDEX_IMG
EOF

    cat > sub.yaml <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nhc-snr
  namespace: openshift-operators
spec:
  name: node-healthcheck-operator
  channel: candidate
  source: medik8s-upstream
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

    # check oc installed
    which oc 2>/dev/null || (
      echo "please install oc"
      exit 1
    )

    # check working cluster config
    oc get node || (
        echo "failed to access cluster, check your $KUBECONFIG"
        exit 1
    )

    # disable default sources with older versions
    oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' || true

    oc apply -f cs.yaml

    echo "waiting a bit to let the CatalogSource come up"
    sleep 10

    oc apply -f sub.yaml

fi
