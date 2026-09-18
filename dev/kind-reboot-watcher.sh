#!/bin/bash
# kind-reboot-watcher.sh — Simulates node reboot on Kind clusters
#
# On real hardware, SNR triggers a reboot (sysrq-trigger or watchdog), which
# restarts the machine and kubelet comes back up. On Kind, the sysrq-trigger
# doesn't work because Kind nodes are containers sharing the host kernel.
#
# This script watches worker nodes and when one becomes NotReady (kubelet
# stopped), it waits for a SelfNodeRemediation CR to be created for that node,
# then restarts the Kind container — simulating what a real reboot does.
# This ensures NHC has detected the unhealthy node and triggered remediation
# before the reboot happens, avoiding races with controller leader failover.
#
# A configurable timeout (--delay) acts as a safety fallback: if no CR appears
# within that time, the container is restarted anyway to prevent the test from
# hanging indefinitely.
#
# Usage:
#   ./kind-reboot-watcher.sh [--name <cluster>] [--delay <seconds>] [--once]
#   MEDIK8S_CLUSTER_NAME=my-cluster ./kind-reboot-watcher.sh &
#
# The script runs in the foreground by default. Use & or dev-reboot-watcher
# to background it. It exits when the cluster is torn down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
REBOOT_DELAY="${MEDIK8S_REBOOT_DELAY:-300}"
CR_POLL_INTERVAL=5
POLL_INTERVAL=5
ONCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --name) CLUSTER_NAME="$2"; shift 2 ;;
        --delay) REBOOT_DELAY="$2"; shift 2 ;;
        --once) ONCE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--name <cluster>] [--delay <seconds>] [--once]"
            echo ""
            echo "Watches Kind worker nodes and restarts their containers when"
            echo "kubelet stops (simulating hardware reboot for SNR e2e tests)."
            echo ""
            echo "Options:"
            echo "  --name <cluster>   Kind cluster name (default: medik8s-dev)"
            echo "  --delay <seconds>  Max wait for remediation CR before forced reboot (default: 300)"
            echo "  --once             Exit after first reboot (for CI)"
            echo ""
            echo "Environment variables:"
            echo "  MEDIK8S_CLUSTER_NAME    Cluster name (default: medik8s-dev)"
            echo "  MEDIK8S_REBOOT_DELAY    Max wait for CR in seconds (default: 300)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Track nodes that are currently being "rebooted" to avoid double-restart
declare -A REBOOTING

echo "[reboot-watcher] Watching Kind cluster '${CLUSTER_NAME}' (timeout: ${REBOOT_DELAY}s)"
echo "[reboot-watcher] Container tool: ${CONTAINER_TOOL}"
echo "[reboot-watcher] Will wait for SelfNodeRemediation CR before restarting nodes."

# Get list of worker node containers
get_worker_nodes() {
    KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}" \
        kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep worker || true
}

# Check if kubelet is running on a node container
is_kubelet_running() {
    local node="$1"
    ${CONTAINER_TOOL} exec "$node" systemctl is-active kubelet &>/dev/null
}

# Check if node is NotReady via kubectl
is_node_not_ready() {
    local node="$1"
    local status
    status=$(${KUBECTL} get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$status" != "True" ]]
}

# Check if a SelfNodeRemediation CR exists for a given node.
# SNR CRs are named after the node and can be in any namespace.
has_remediation_cr() {
    local node="$1"
    ${KUBECTL} get selfnoderemediation -A --field-selector="metadata.name=${node}" \
        --no-headers 2>/dev/null | grep -q .
}

# Wait for a SelfNodeRemediation CR to appear for the node, or until timeout.
# Returns 0 if CR found, 1 if timed out.
wait_for_remediation_cr() {
    local node="$1"
    local timeout="$2"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if has_remediation_cr "$node"; then
            return 0
        fi
        sleep "$CR_POLL_INTERVAL"
        elapsed=$((elapsed + CR_POLL_INTERVAL))
    done
    return 1
}

while true; do
    # Check cluster still exists
    if ! KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}" kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        echo "[reboot-watcher] Cluster '${CLUSTER_NAME}' gone, exiting."
        exit 0
    fi

    WORKERS=$(get_worker_nodes)
    if [ -z "$WORKERS" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    for node in $WORKERS; do
        # Skip nodes already being rebooted
        if [[ -n "${REBOOTING[$node]:-}" ]]; then
            # Check if reboot completed (kubelet running again)
            if is_kubelet_running "$node"; then
                echo "[reboot-watcher] $node: kubelet is back, reboot complete."
                unset "REBOOTING[$node]"
            fi
            continue
        fi

        # Detect stopped kubelet (node becoming NotReady)
        if is_node_not_ready "$node" && ! is_kubelet_running "$node"; then
            echo "[reboot-watcher] $node: kubelet stopped, NotReady detected."
            echo "[reboot-watcher] $node: waiting for SelfNodeRemediation CR (timeout: ${REBOOT_DELAY}s)..."
            REBOOTING[$node]=1

            # Wait for CR then restart in background so we keep watching other nodes
            (
                if wait_for_remediation_cr "$node" "$REBOOT_DELAY"; then
                    echo "[reboot-watcher] $node: SelfNodeRemediation CR found, restarting container..."
                else
                    echo "[reboot-watcher] $node: timeout waiting for CR, forcing restart..."
                fi
                ${CONTAINER_TOOL} restart "$node"
                echo "[reboot-watcher] $node: container restarted, waiting for kubelet..."
            ) &

            if [ "$ONCE" = true ]; then
                wait
                echo "[reboot-watcher] --once mode, exiting after first reboot."
                exit 0
            fi
        fi
    done

    sleep "$POLL_INTERVAL"
done
