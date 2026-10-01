#!/bin/bash
# Medik8s development environment teardown
# Destroys the Kind cluster created by setup.sh
#
# Usage: ./teardown.sh [--name <cluster-name>]
# KEEP_REGISTRY=true preserves a registry shared with other clusters.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
REG_NAME="${MEDIK8S_REGISTRY_NAME:-kind-registry}"

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

if [ "${KIND_BLOCK_STORAGE:-false}" = true ]; then
    source "${SCRIPT_DIR}/kind-block.sh"
    kind_block_state
    # An unowned cluster must never be removed by fixture cleanup.
    if [ ! -f "$KIND_BLOCK_STATE_DIR/owned" ]; then
        echo "No owned Kind block environment to clean up."
        exit 0
    fi
    if [[ "${CONTAINER_TOOL}" != "docker" && "${CONTAINER_TOOL}" != "podman" ]]; then
        echo "Block fixture cleanup requires CONTAINER_TOOL=docker or podman." >&2
        exit 1
    fi
    kind_block_check_host
fi

if ! command -v kind &>/dev/null; then
    echo "Error: kind is not installed."
    exit 1
fi

export KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "=== Deleting Kind cluster '${CLUSTER_NAME}' ==="

    # Dynamically unmount all active NFS, CSI, and volume mounts listed in /proc/mounts
    # before cluster deletion to prevent processes hanging in kernel uninterruptible sleep (D-state).
    NODES=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null || true)
    for node in ${NODES}; do
        ${CONTAINER_TOOL} exec "$node" sh -c \
            "grep -E '/var/lib/kubelet|/mnt' /proc/mounts | awk '{print \$2}' | xargs -r -n1 umount -f -l 2>/dev/null || true" 2>/dev/null || true
    done

    # Attempt standard cluster deletion with a fallback forced container removal if Docker/runc hangs
    kind delete cluster --name "${CLUSTER_NAME}" || {
        echo "Warning: 'kind delete cluster' encountered an error; forcing container removal..."
        ${CONTAINER_TOOL} ps -a -q --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" | xargs -r ${CONTAINER_TOOL} rm -f -v 2>/dev/null || true
    }
    echo "Done."
elif ${KUBECTL} cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1; then
    echo "Cluster '${CLUSTER_NAME}' exists but is not visible to 'kind get clusters'."
    echo "It was likely created with sudo. Delete it with:"
    echo "  sudo kind delete cluster --name ${CLUSTER_NAME}"
    exit 1
else
    echo "Cluster '${CLUSTER_NAME}' does not exist."
fi

# Clean up block storage state if applicable
if [ "${KIND_BLOCK_STORAGE:-false}" = true ]; then
    kind_block_cleanup
fi

# SKIP_REGISTRY controls setup; KEEP_REGISTRY preserves a borrowed registry during teardown.
if [ "${KEEP_REGISTRY:-false}" != true ] && ${CONTAINER_TOOL} inspect "${REG_NAME}" &>/dev/null; then
    echo "=== Removing local registry '${REG_NAME}' ==="
    ${CONTAINER_TOOL} rm -f "${REG_NAME}"
fi
