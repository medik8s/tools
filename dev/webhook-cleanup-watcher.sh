#!/bin/bash
# webhook-cleanup-watcher.sh — Continuously removes duplicate OLM webhook configurations
#
# When multiple operators (e.g., SNR + NHC) are deployed in the same namespace
# via OLM, OLM copies CSVs and creates duplicate webhook configurations that
# point to wrong services. This causes webhook calls to fail with errors like:
#   "failed calling webhook: the server could not find the requested resource"
#
# OLM's reconciler re-creates these duplicates, so a one-shot cleanup is not
# enough. This watcher runs in the background and continuously removes them.
#
# Usage:
#   ./webhook-cleanup-watcher.sh &
#   MEDIK8S_CLUSTER_NAME=my-cluster ./webhook-cleanup-watcher.sh &

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
POLL_INTERVAL="${MEDIK8S_WEBHOOK_POLL:-10}"

echo "[webhook-watcher] Watching for duplicate OLM webhook configurations (poll: ${POLL_INTERVAL}s)"

# Mapping of webhook name patterns to their owning operator.
# A webhook matching a pattern should only be owned by the corresponding operator's CSV.
declare -A WEBHOOK_OWNERS=(
    [selfnoderemediation]="self-node-remediation"
    [nodehealthcheck]="node-healthcheck"
    [fenceagentsremediation]="fence-agents-remediation"
    [machinedeletionremediation]="machine-deletion-remediation"
    [nodemaintenance]="node-maintenance"
)

cleanup_duplicates() {
    local cleaned=0

    for pattern in "${!WEBHOOK_OWNERS[@]}"; do
        local owner_match="${WEBHOOK_OWNERS[$pattern]}"

        # Check mutating webhooks
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local wh_name owner
            wh_name=$(echo "$line" | awk '{print $1}')
            owner=$(echo "$line" | awk '{print $2}')

            # Skip if owned by the correct operator
            if echo "$owner" | grep -q "$owner_match"; then
                continue
            fi

            # Skip webhooks without an OLM owner (not created by OLM)
            if [ "$owner" = "<none>" ] || [ -z "$owner" ]; then
                continue
            fi

            echo "[webhook-watcher] Deleting duplicate mutatingwebhookconfiguration/${wh_name} (owner: ${owner}, should be: ${owner_match})"
            ${KUBECTL} delete "mutatingwebhookconfiguration/${wh_name}" 2>/dev/null || true
            cleaned=$((cleaned + 1))
        done < <(${KUBECTL} get mutatingwebhookconfigurations -o custom-columns=NAME:.metadata.name,OWNER:.metadata.labels.olm\\.owner --no-headers 2>/dev/null | grep "$pattern" || true)

        # Check validating webhooks
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local wh_name owner
            wh_name=$(echo "$line" | awk '{print $1}')
            owner=$(echo "$line" | awk '{print $2}')

            # Skip if owned by the correct operator
            if echo "$owner" | grep -q "$owner_match"; then
                continue
            fi

            # Skip webhooks without an OLM owner (not created by OLM)
            if [ "$owner" = "<none>" ] || [ -z "$owner" ]; then
                continue
            fi

            echo "[webhook-watcher] Deleting duplicate validatingwebhookconfiguration/${wh_name} (owner: ${owner}, should be: ${owner_match})"
            ${KUBECTL} delete "validatingwebhookconfiguration/${wh_name}" 2>/dev/null || true
            cleaned=$((cleaned + 1))
        done < <(${KUBECTL} get validatingwebhookconfigurations -o custom-columns=NAME:.metadata.name,OWNER:.metadata.labels.olm\\.owner --no-headers 2>/dev/null | grep "$pattern" || true)
    done

    return $cleaned
}

while true; do
    # Check cluster still exists (for Kind clusters)
    if command -v kind &>/dev/null; then
        if ! KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}" kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
            echo "[webhook-watcher] Cluster '${CLUSTER_NAME}' gone, exiting."
            exit 0
        fi
    fi

    cleanup_duplicates || true

    sleep "$POLL_INTERVAL"
done
