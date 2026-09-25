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
# Three modes (--mode):
#   snr (default) — waits for a SelfNodeRemediation CR to appear for the node.
#                   This ensures NHC has triggered remediation before reboot,
#                   avoiding races with controller leader failover.
#   sbr           — waits for StorageBasedRemediation FencingSucceeded=True.
#                   This keeps the node down long enough for the victim's
#                   heartbeat to age past maxHeartbeatAge (60s); restarting
#                   sooner would let the agent resume heartbeating and fencing
#                   would never confirm. Also re-creates the per-node null
#                   /dev/watchdog device after restart (see setup-null-device-watchdog.sh).
#   far           — fence agent mode for FenceAgentsRemediation on Kind. Acts as
#                   a one-shot fence agent: executes --action on the container
#                   named by --plug via the Docker REST API (--unix-socket).
#                   Does not require kubectl or a container tool in PATH since it
#                   uses curl to speak directly to the Docker socket. This lets
#                   the script run inside the FAR operator pod where only curl
#                   is available.
#
# A configurable timeout (--delay) acts as a safety fallback: if the expected
# signal does not appear within that time, the container is restarted anyway to
# prevent the test from hanging indefinitely.
#
# Usage:
#   ./kind-reboot-watcher.sh [--name <cluster>] [--delay <seconds>] [--once] [--mode snr|sbr]
#   ./kind-reboot-watcher.sh --mode far --action reboot --plug <container> [--unix-socket <path>]
#   MEDIK8S_CLUSTER_NAME=my-cluster ./kind-reboot-watcher.sh &
#
# The script runs in the foreground by default. Use & or dev-reboot-watcher
# to background it. It exits when the cluster is torn down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
REBOOT_DELAY="${MEDIK8S_REBOOT_DELAY:-300}"
MODE="${MEDIK8S_REBOOT_WATCHER_MODE:-snr}"
ACTION=""
PLUG=""
SOCKET="/var/run/docker.sock"
CR_POLL_INTERVAL=5
POLL_INTERVAL=5
ONCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --name) CLUSTER_NAME="$2"; shift 2 ;;
        --delay) REBOOT_DELAY="$2"; shift 2 ;;
        --once) ONCE=true; shift ;;
        --mode=*) MODE="${1#*=}"; shift ;;
        --mode) MODE="$2"; shift 2 ;;
        --action=*) ACTION="${1#*=}"; shift ;;
        --action) ACTION="$2"; shift 2 ;;
        --plug=*) PLUG="${1#*=}"; shift ;;
        --plug) PLUG="$2"; shift 2 ;;
        --unix-socket=*) SOCKET="${1#*=}"; shift ;;
        --unix-socket) SOCKET="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--name <cluster>] [--delay <seconds>] [--once] [--mode snr|sbr|far]"
            echo ""
            echo "Watches Kind worker nodes and restarts their containers when"
            echo "kubelet stops (simulating hardware reboot for e2e tests)."
            echo ""
            echo "Options:"
            echo "  --name <cluster>       Kind cluster name (default: medik8s-dev)"
            echo "  --delay <seconds>      Max wait for remediation signal before forced reboot (default: 300)"
            echo "  --once                 Exit after first reboot (for CI)"
            echo "  --mode snr|sbr|far     Remediation mode (default: snr)"
            echo "                           snr: wait for SelfNodeRemediation CR"
            echo "                           sbr: wait for StorageBasedRemediation FencingSucceeded=True"
            echo "                           far: fence agent mode — one-shot restart via Docker socket"
            echo "  --action reboot|on|off|status Action for --mode far"
            echo "  --plug <container>     Container name for --mode far"
            echo "  --unix-socket <path>   Docker socket path for --mode far (default: /var/run/docker.sock)"
            echo ""
            echo "Environment variables:"
            echo "  MEDIK8S_CLUSTER_NAME         Cluster name (default: medik8s-dev)"
            echo "  MEDIK8S_REBOOT_DELAY         Max wait for signal in seconds (default: 300)"
            echo "  MEDIK8S_REBOOT_WATCHER_MODE  Mode: snr, sbr, or far (default: snr)"
            exit 0
            ;;
        *) shift ;;  # ignore unknown args (fence agent may pass extra params)
    esac
done

# far mode: one-shot fence agent that restarts a Kind container via Docker REST API.
# Uses curl so it works inside operator pods that have no docker/podman CLI.
if [[ "$MODE" == "far" ]]; then
    [[ -z "$ACTION" ]] && { echo "Error: --mode far requires --action"; exit 1; }
    [[ -z "$PLUG" ]] && { echo "Error: --mode far requires --plug"; exit 1; }

    docker_api() {
        local path="$1"
        curl --unix-socket "$SOCKET" -s -o /dev/null -w "%{http_code}" \
            -X POST "http://localhost$path"
    }

    case "$ACTION" in
        reboot)
            code=$(docker_api "/containers/$PLUG/restart")
            [[ "$code" == "204" ]] && { echo "Status: ON"; exit 0; } || { echo "restart failed (HTTP $code)"; exit 1; }
            ;;
        on)
            code=$(docker_api "/containers/$PLUG/start")
            [[ "$code" == "204" || "$code" == "304" ]] && { echo "Status: ON"; exit 0; } || { echo "start failed (HTTP $code)"; exit 1; }
            ;;
        off)
            code=$(docker_api "/containers/$PLUG/stop")
            [[ "$code" == "204" || "$code" == "304" ]] && { echo "Status: OFF"; exit 0; } || { echo "stop failed (HTTP $code)"; exit 1; }
            ;;
        status)
            # GET /containers/{name}/json returns 200 + JSON if found, 404 if not.
            body=$(curl --unix-socket "$SOCKET" -s -w "\n%{http_code}" \
                "http://localhost/containers/$PLUG/json")
            http_code=$(echo "$body" | tail -1)
            if [[ "$http_code" != "200" ]]; then
                echo "Status: OFF"
                exit 1
            fi
            running=$(echo "$body" | grep -o '"Running":[^,}]*' | cut -d: -f2 | tr -d ' ')
            if [[ "$running" == "true" ]]; then
                echo "Status: ON"
                exit 0
            else
                echo "Status: OFF"
                exit 1
            fi
            ;;
        *)
            echo "Error: unknown action '$ACTION' for --mode far (expected: reboot, on, off, status)"
            exit 1
            ;;
    esac
fi

if [[ "$MODE" != "snr" && "$MODE" != "sbr" ]]; then
    echo "Error: --mode must be 'snr', 'sbr', or 'far', got: '$MODE'"
    exit 1
fi

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

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

is_node_ready() {
    local node="$1"
    local status
    status=$(${KUBECTL} get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$status" == "True" ]]
}

# --- SNR mode ---

# Return the UID of the current SelfNodeRemediation CR for a node, or empty string.
get_snr_cr_uid() {
    local node="$1"
    ${KUBECTL} get selfnoderemediation -A --field-selector="metadata.name=${node}" \
        -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true
}

# Wait for a NEW SelfNodeRemediation CR (different UID from baseline) to appear.
# Returns 0 when a new CR is found, 1 on timeout.
wait_for_remediation_cr() {
    local node="$1"
    local timeout="$2"
    local baseline_uid="$3"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local uid
        uid=$(get_snr_cr_uid "$node")
        if [ -n "$uid" ] && [ "$uid" != "$baseline_uid" ]; then
            return 0
        fi
        sleep "$CR_POLL_INTERVAL"
        elapsed=$((elapsed + CR_POLL_INTERVAL))
    done
    return 1
}

# --- SBR mode ---

# Return "UID:status" for the current StorageBasedRemediation CR, or empty.
get_sbr_cr_fencing_state() {
    local node="$1"
    ${KUBECTL} get storagebasedremediation -A \
        --field-selector="metadata.name=${node}" \
        -o jsonpath='{.items[0].metadata.uid}:{range .items[0].status.conditions[?(@.type=="FencingSucceeded")]}{.status}{end}' \
        2>/dev/null || true
}

# Wait until a NEW StorageBasedRemediation CR (different UID from baseline) reaches
# FencingSucceeded=True, or until timeout.
wait_for_fencing() {
    local node="$1"
    local timeout="$2"
    local baseline_uid="$3"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local state uid fencing_status
        state=$(get_sbr_cr_fencing_state "$node")
        uid="${state%%:*}"
        fencing_status="${state#*:}"
        if [ -n "$uid" ] && [ "$uid" != "$baseline_uid" ] && [ "$fencing_status" = "True" ]; then
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
            # Check if reboot completed (node Ready again)
            if is_node_ready "$node"; then
                log "$node: node is Ready again, reboot complete."
                REBOOTING=$(echo "$REBOOTING" | tr ' ' '\n' | grep -vxF "$node" | tr '\n' ' ')
            fi
            continue
        fi

        # Detect node becoming NotReady (covers stopped kubelet and network partition).
        # Sleep briefly to let transient NotReady states (cert rotation, resource pressure)
        # recover on their own before committing to a restart.
        if ! is_node_ready "$node"; then
            sleep 10
            if is_node_ready "$node"; then
                continue
            fi
            log "$node: NotReady detected."
            REBOOTING="$REBOOTING $node"

            if [ "$MODE" = "snr" ]; then
                # Capture baseline UID so we wait for a freshly-created CR, not a stale one.
                local_baseline_uid=$(get_snr_cr_uid "$node")
                log "$node: waiting for new SelfNodeRemediation CR (baseline UID: ${local_baseline_uid:-none}, timeout: ${REBOOT_DELAY}s)..."
                (
                    if wait_for_remediation_cr "$node" "$REBOOT_DELAY" "$local_baseline_uid"; then
                        log "$node: new SelfNodeRemediation CR found, restarting container..."
                    else
                        log "$node: timeout waiting for CR, forcing restart..."
                    fi
                    ${CONTAINER_TOOL} restart "$node"
                    log "$node: container restarted, waiting for kubelet..."
                ) &
            else
                # Capture baseline UID so a stale FencingSucceeded from a prior remediation
                # does not prematurely trigger a restart for the current one.
                local_baseline_uid=$(get_sbr_cr_fencing_state "$node"); local_baseline_uid="${local_baseline_uid%%:*}"
                log "$node: waiting for FencingSucceeded=True on new CR (baseline UID: ${local_baseline_uid:-none}, timeout: ${REBOOT_DELAY}s)..."
                (
                    if wait_for_fencing "$node" "$REBOOT_DELAY" "$local_baseline_uid"; then
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
