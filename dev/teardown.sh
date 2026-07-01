#!/bin/bash
# Medik8s development environment teardown
# Destroys the Kind cluster created by setup.sh
#
# Usage: ./teardown.sh [--name <cluster-name>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if ! command -v kind &>/dev/null; then
    echo "Error: kind is not installed."
    exit 1
fi

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "=== Deleting Kind cluster '${CLUSTER_NAME}' ==="
    kind delete cluster --name "${CLUSTER_NAME}"
    echo "Done."
elif ${KUBECTL} cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1; then
    echo "Cluster '${CLUSTER_NAME}' exists but is not visible to 'kind get clusters'."
    echo "It was likely created with sudo. Delete it with:"
    echo "  sudo kind delete cluster --name ${CLUSTER_NAME}"
    exit 1
else
    echo "Cluster '${CLUSTER_NAME}' does not exist."
fi
