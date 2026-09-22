#!/bin/bash
# kind-reboot-watcher.sh — Simulates node reboot on Kind clusters
#
# On real hardware, SNR/SBR triggers a reboot, which restarts the machine and
# kubelet comes back up. On Kind, the sysrq-trigger doesn't work because Kind
# nodes are containers sharing the host kernel.
#
# This script watches worker nodes and when one becomes NotReady (kubelet
# stopped), it waits for a remediation signal before restarting the Kind
# container — simulating what a real reboot does.
#
# Two modes (--mode):
#   snr (default) — waits for a SelfNodeRemediation CR to appear for the node.
#                   This ensures NHC has triggered remediation before reboot,
#                   avoiding races with controller leader failover.
#   sbr           — waits for StorageBasedRemediation FencingSucceeded=True.
#                   This keeps the node down long enough for the victim's
#                   heartbeat to age past maxHeartbeatAge (60s); restarting
#                   sooner would let the agent resume heartbeating and fencing
#                   would never confirm. Also re-creates the per-node null
#                   /dev/watchdog device after restart (see setup-null-device-watchdog.sh).
#
# A configurable timeout (--delay) acts as a safety fallback: if the expected
# signal does not appear within that time, the container is restarted anyway to
# prevent the test from hanging indefinitely.
#
# Usage:
#   ./kind-reboot-watcher.sh [--name <cluster>] [--delay <seconds>] [--once] [--mode snr|sbr]
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
MODE="${MEDIK8S_REBOOT_WATCHER_MODE:-snr}"
CR_POLL_INTERVAL=5
POLL_INTERVAL=5
ONCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --name) CLUSTER_NAME="$2"; shift 2 ;;
        --delay) REBOOT_DELAY="$2"; shift 2 ;;
        --once) ONCE=true; shift ;;
        --mode) MODE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--name <cluster>] [--delay <seconds>] [--once] [--mode snr|sbr]"
            echo ""
            echo "Watches Kind worker nodes and restarts their containers when"
            echo "kubelet stops (simulating hardware reboot for e2e tests)."
            echo ""
            echo "Options:"
            echo "  --name <cluster>   Kind cluster name (default: medik8s-dev)"
            echo "  --delay <seconds>  Max wait for remediation signal before forced reboot (default: 300)"
            echo "  --once             Exit after first reboot (for CI)"
            echo "  --mode snr|sbr     Remediation mode (default: snr)"
            echo "                       snr: wait for SelfNodeRemediation CR"
            echo "                       sbr: wait for StorageBasedRemediation FencingSucceeded=True"
            echo ""
            echo "Environment variables:"
            echo "  MEDIK8S_CLUSTER_NAME         Cluster name (default: medik8s-dev)"
            echo "  MEDIK8S_REBOOT_DELAY         Max wait for signal in seconds (default: 300)"
            echo "  MEDIK8S_REBOOT_WATCHER_MODE  Mode: snr or sbr (default: snr)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ "$MODE" != "snr" && "$MODE" != "sbr" ]]; then
    echo "Error: --mode must be 'snr' or 'sbr', got: '$MODE'"
    exit 1
fi

log() { echo "$(date -u +%H:%M:%S) [reboot-watcher/$MODE] $*"; }

# Track nodes that are currently being "rebooted" to avoid double-restart (space-separated list)
REBOOTING=""

log "watching Kind cluster '${CLUSTER_NAME}' (timeout: ${REBOOT_DELAY}s, tool: ${CONTAINER_TOOL})"
if [ "$MODE" = "snr" ]; then
    log "will wait for SelfNodeRemediation CR before restarting nodes."
else
    log "will wait for StorageBasedRemediation FencingSucceeded=True before restarting nodes."
fi

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

# --- SNR mode ---

# Check if a SelfNodeRemediation CR exists for a given node.
has_remediation_cr() {
    local node="$1"
    ${KUBECTL} get selfnoderemediation -A --field-selector="metadata.name=${node}" \
        --no-headers 2>/dev/null | grep -q .
}

# Wait for a SelfNodeRemediation CR to appear for the node, or until timeout.
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

# --- SBR mode ---

# Check if StorageBasedRemediation FencingSucceeded=True for a node.
fencing_succeeded() {
    local node="$1" out
    out=$(${KUBECTL} get storagebasedremediation -A \
        --field-selector="metadata.name=${node}" \
        -o jsonpath='{range .items[*].status.conditions[?(@.type=="FencingSucceeded")]}{.status}{end}' \
        2>/dev/null)
    [[ "$out" == *"True"* ]]
}

# Wait until FencingSucceeded=True for the node, or until timeout.
wait_for_fencing() {
    local node="$1"
    local timeout="$2"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if fencing_succeeded "$node"; then
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
        log "cluster '${CLUSTER_NAME}' gone, exiting."
        exit 0
    fi

    WORKERS=$(get_worker_nodes)
    if [ -z "$WORKERS" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    for node in $WORKERS; do
        # Skip nodes already being rebooted
        if echo " $REBOOTING " | grep -qF " $node "; then
            # Check if reboot completed (kubelet running again)
            if is_kubelet_running "$node"; then
                log "$node: kubelet is back, reboot complete."
                REBOOTING=$(echo "$REBOOTING" | tr ' ' '\n' | grep -vF "$node" | tr '\n' ' ')
            fi
            continue
        fi

        # Detect stopped kubelet (node becoming NotReady)
        if is_node_not_ready "$node" && ! is_kubelet_running "$node"; then
            log "$node: kubelet stopped, NotReady detected."
            REBOOTING="$REBOOTING $node"

            if [ "$MODE" = "snr" ]; then
                log "$node: waiting for SelfNodeRemediation CR (timeout: ${REBOOT_DELAY}s)..."
                (
                    if wait_for_remediation_cr "$node" "$REBOOT_DELAY"; then
                        log "$node: SelfNodeRemediation CR found, restarting container..."
                    else
                        log "$node: timeout waiting for CR, forcing restart..."
                    fi
                    ${CONTAINER_TOOL} restart "$node"
                    log "$node: container restarted, waiting for kubelet..."
                ) &
            else
                log "$node: waiting for FencingSucceeded=True (timeout: ${REBOOT_DELAY}s)..."
                (
                    if wait_for_fencing "$node" "$REBOOT_DELAY"; then
                        log "$node: FencingSucceeded=True, restarting container to complete reboot..."
                    else
                        log "$node: timeout waiting for FencingSucceeded, forcing restart..."
                    fi
                    ${CONTAINER_TOOL} restart "$node" >/dev/null 2>&1 || true
                    # Re-create the per-node null watchdog device (lost on container restart).
                    ${CONTAINER_TOOL} exec "$node" sh -c 'rm -f /dev/watchdog; mknod /dev/watchdog c 1 3' 2>/dev/null || true
                    log "$node: container restarted, waiting for kubelet to return."
                ) &
            fi

            if [ "$ONCE" = true ]; then
                wait
                log "--once mode, exiting after first reboot."
                exit 0
            fi
        fi
    done

    sleep "$POLL_INTERVAL"
done
