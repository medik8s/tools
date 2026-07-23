#!/bin/bash
# Show remediation flow timeline — what happened during simulate/recover.
# Usage: summary.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

echo "========================================"
echo "  Remediation Flow Summary"
echo "========================================"
echo ""

echo "--- Nodes ---"
${KUBECTL} get nodes -o wide 2>/dev/null
echo ""

echo "--- NHC Status ---"
NHCS=$(${KUBECTL} get nodehealthcheck --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
if [ -n "$NHCS" ]; then
    for nhc in $NHCS; do
        PHASE=$(${KUBECTL} get nodehealthcheck "$nhc" -o jsonpath='{.status.phase}' 2>/dev/null)
        HEALTHY=$(${KUBECTL} get nodehealthcheck "$nhc" -o jsonpath='{.status.healthyNodes}' 2>/dev/null)
        OBSERVED=$(${KUBECTL} get nodehealthcheck "$nhc" -o jsonpath='{.status.observedNodes}' 2>/dev/null)
        echo "  ${nhc}: Phase=${PHASE:-N/A}  Nodes: ${HEALTHY:-0}/${OBSERVED:-0} healthy"
    done
else
    echo "  (no NodeHealthCheck CRs found)"
fi
echo ""

echo "--- Active Remediation CRs ---"
SNRS_OUT=$(${KUBECTL} get selfnoderemediation -A --no-headers 2>/dev/null || true)
FARS_OUT=$(${KUBECTL} get fenceagentsremediation -A --no-headers 2>/dev/null || true)
[ -n "$SNRS_OUT" ] && echo "$SNRS_OUT" | awk '{print "  " $2 " (ns: " $1 ")"}'
[ -n "$FARS_OUT" ] && echo "$FARS_OUT" | awk '{print "  " $2 " (ns: " $1 ")"}'
SNRS=$(echo "$SNRS_OUT" | grep -c . || true)
FARS=$(echo "$FARS_OUT" | grep -c . || true)
if [ "$SNRS" -eq 0 ] && [ "$FARS" -eq 0 ]; then
    echo "  (none — all remediation completed)"
fi
echo ""

echo "--- Remediation Timeline ---"
${KUBECTL} get events -A --sort-by=.lastTimestamp 2>/dev/null \
    | grep -E 'NodeNotReady|RemediationStarted|AddFinalizer|UpdateTimeAssumedRebooted|TaintManagerEviction|RemediationFinished|RemoveFinalizer' \
    | awk '{printf "  %-8s %-10s %-50s %s\n", $1, $2, $5, substr($0, index($0,$6))}' \
    || echo "  No remediation events found."
echo ""

echo "--- Operator Pods ---"
${KUBECTL} get pods -A -l control-plane=controller-manager --no-headers \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount \
    2>/dev/null || echo "  (none)"
