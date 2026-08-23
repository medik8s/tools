#!/bin/bash
# Show a full summary of all medik8s resources in the dev cluster.
# Usage: describe.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

echo "========================================"
echo "  Medik8s Dev Environment Summary"
echo "========================================"
echo ""

echo "--- Nodes ---"
${KUBECTL} get nodes -o wide 2>/dev/null || true
echo ""

echo "--- Operator Pods ---"
PODS_FOUND=false
for label in control-plane=controller-manager app.kubernetes.io/component=controller-manager; do
    RESULT=$(${KUBECTL} get pods -A -l "$label" \
        -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount \
        --no-headers 2>/dev/null)
    if [ -n "$RESULT" ]; then
        if [ "$PODS_FOUND" = false ]; then
            echo "  NAMESPACE  NAME  NODE  STATUS  RESTARTS"
        fi
        echo "$RESULT" | while IFS= read -r line; do echo "  $line"; done
        PODS_FOUND=true
    fi
done
if [ "$PODS_FOUND" = false ]; then
    echo "  (none)"
fi
echo ""

# NodeHealthCheck
if ${KUBECTL} get crd nodehealthchecks.remediation.medik8s.io >/dev/null 2>&1; then
    echo "--- NodeHealthCheck ---"
    NHCS=$(${KUBECTL} get nodehealthcheck --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
    if [ -n "$NHCS" ]; then
        for nhc in $NHCS; do
            echo ""
            echo "  ${nhc}:"
            PHASE=$(${KUBECTL} get nodehealthcheck "$nhc" -o jsonpath='{.status.phase}' 2>/dev/null)
            HEALTHY=$(${KUBECTL} get nodehealthcheck "$nhc" -o jsonpath='{.status.healthyNodes}' 2>/dev/null)
            OBSERVED=$(${KUBECTL} get nodehealthcheck "$nhc" -o jsonpath='{.status.observedNodes}' 2>/dev/null)
            UNHEALTHY=$(${KUBECTL} get nodehealthcheck "$nhc" -o jsonpath='{.status.unhealthyNodes}' 2>/dev/null)
            MIN_HEALTHY=$(${KUBECTL} get nodehealthcheck "$nhc" -o jsonpath='{.spec.minHealthy}' 2>/dev/null)
            echo "    Phase: ${PHASE:-N/A}"
            echo "    Nodes: ${HEALTHY:-0} healthy / ${OBSERVED:-0} observed (${UNHEALTHY:-0} unhealthy)"
            echo "    MinHealthy: ${MIN_HEALTHY:-N/A}"
        done
    else
        echo "  (none) — create with: make dev-create-nhc"
    fi
    echo ""
fi

# SelfNodeRemediation
if ${KUBECTL} get crd selfnoderemediations.self-node-remediation.medik8s.io >/dev/null 2>&1; then
    echo "--- SelfNodeRemediation ---"
    if ${KUBECTL} get selfnoderemediation -A --no-headers 2>/dev/null | grep -q .; then
        ${KUBECTL} get selfnoderemediation -A \
            -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STARTED:.status.startTime,PHASE:.status.phase \
            2>/dev/null
    else
        echo "  (none)"
    fi
    echo ""
    echo "  Templates:"
    ${KUBECTL} get selfnoderemediationtemplate -A --no-headers 2>/dev/null \
        | awk '{print "    " $2 " (ns: " $1 ")"}' || echo "    (none)"
    echo ""
    echo "  Config:"
    ${KUBECTL} get selfnoderemediationconfig -A --no-headers 2>/dev/null \
        | awk '{print "    " $2 " (ns: " $1 ")"}' || echo "    (none)"
    echo ""
fi

# FenceAgentsRemediation
if ${KUBECTL} get crd fenceagentsremediations.fence-agents-remediation.medik8s.io >/dev/null 2>&1; then
    echo "--- FenceAgentsRemediation ---"
    ${KUBECTL} get fenceagentsremediation -A 2>/dev/null | head -10 || echo "  (none)"
    echo ""
fi

# MachineDeletionRemediation
if ${KUBECTL} get crd machinedeletionremediations.machine-deletion-remediation.medik8s.io >/dev/null 2>&1; then
    echo "--- MachineDeletionRemediation ---"
    ${KUBECTL} get machinedeletionremediation -A 2>/dev/null | head -10 || echo "  (none)"
    echo ""
fi

# NodeMaintenance
if ${KUBECTL} get crd nodemaintenances.nodemaintenance.medik8s.io >/dev/null 2>&1; then
    echo "--- NodeMaintenance ---"
    ${KUBECTL} get nodemaintenance -A 2>/dev/null | head -10 || echo "  (none)"
    echo ""
fi

# Leases
if ${KUBECTL} get namespace medik8s-leases >/dev/null 2>&1; then
    echo "--- Leases (medik8s-leases) ---"
    if ${KUBECTL} get leases -n medik8s-leases --no-headers 2>/dev/null | grep -q .; then
        ${KUBECTL} get leases -n medik8s-leases 2>/dev/null
    else
        echo "  (none)"
    fi
    echo ""
fi

# Leader election
echo "--- Leader Election ---"
LEADER_FOUND=false
for label in control-plane=controller-manager app.kubernetes.io/component=controller-manager; do
    for ns in $(${KUBECTL} get deployment -A -l "$label" --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | sort -u); do
        for lease in $(${KUBECTL} get leases -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
            HOLDER=$(${KUBECTL} get lease "$lease" -n "$ns" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
            if [ -n "$HOLDER" ]; then
                echo "  $ns/$lease → $HOLDER"
                LEADER_FOUND=true
            fi
        done
    done
done
if [ "$LEADER_FOUND" = false ]; then
    echo "  (none)"
fi
echo ""

# Recent events — includes both CR and node events
echo "--- Recent Remediation Events ---"
${KUBECTL} get events -A --sort-by=.lastTimestamp 2>/dev/null \
    | grep -iE 'remediat|healthcheck|maintenance|fence|unhealthy|notready' \
    | tail -10 || echo "  (none)"
