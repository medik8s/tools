#!/bin/bash
# Verify RBAC correctness for Medik8s operators in non-OLM deployments.
#
# OLM silently promotes namespace-scoped Roles to ClusterRoles when using
# AllNamespaces install mode. Non-OLM deployments (make deploy, kustomize)
# use the RBAC manifests as-is, exposing mismatches between namespace-scoped
# permissions and cluster-scoped runtime behavior.
#
# Known bug classes:
#   1. Secret cache: controller-runtime creates a cluster-scoped Secret
#      informer, but RBAC only grants namespace-scoped Secret access.
#   2. Events on cluster-scoped objects: client-go emits events in the
#      default namespace for cluster-scoped resources, but events RBAC
#      is only in the namespace-scoped leader_election_role.
#
# Usage: ./verify-rbac.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PASS=0
FAIL=0

check() {
    local sa="$1" ns="$2" verb="$3" resource="$4" scope="$5" label="$6"
    local result

    if [ "$scope" = "cluster" ]; then
        result=$(${KUBECTL} auth can-i "$verb" "$resource" \
            --as="system:serviceaccount:${ns}:${sa}" 2>/dev/null || true)
    else
        result=$(${KUBECTL} auth can-i "$verb" "$resource" \
            --as="system:serviceaccount:${ns}:${sa}" \
            -n "$scope" 2>/dev/null || true)
    fi

    if [ "$result" = "yes" ]; then
        printf "  PASS  %-50s %s/%s (scope: %s)\n" "$label" "$verb" "$resource" "$scope"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %-50s %s/%s (scope: %s)\n" "$label" "$verb" "$resource" "$scope"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Medik8s RBAC Verification (non-OLM deployment) ==="
echo ""

FOUND_ANY=false

for ns in $(${KUBECTL} get namespace --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | \
    grep -E 'medik8s|fence-agents|self-node|node-healthcheck|node-maintenance|machine-deletion|storage-based'); do

    SA_LIST=$(${KUBECTL} get serviceaccount -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | \
        grep -E 'controller-manager' || true)

    for sa in $SA_LIST; do
        FOUND_ANY=true
        echo "--- ${ns}/${sa} ---"

        OPERATOR=""
        case "$ns" in
            *fence-agents*|*far*) OPERATOR="FAR" ;;
            *self-node*|*snr*) OPERATOR="SNR" ;;
            *node-healthcheck*|*nhc*) OPERATOR="NHC" ;;
            *node-maintenance*|*nmo*) OPERATOR="NMO" ;;
            *machine-deletion*|*mdr*) OPERATOR="MDR" ;;
            *storage-based*|*sbr*) OPERATOR="SBR" ;;
            *medik8s*) OPERATOR="unknown" ;;
        esac

        # Bug class 1: Secret cache — cluster-scoped list/watch
        check "$sa" "$ns" "list" "secrets" "cluster" "${OPERATOR}: cluster-scoped secret list"
        check "$sa" "$ns" "watch" "secrets" "cluster" "${OPERATOR}: cluster-scoped secret watch"

        # Bug class 2: Events on cluster-scoped objects — events in default namespace
        check "$sa" "$ns" "create" "events" "default" "${OPERATOR}: create events in default ns"
        check "$sa" "$ns" "patch" "events" "default" "${OPERATOR}: patch events in default ns"

        # Also check events in operator namespace (leader election needs this)
        check "$sa" "$ns" "create" "events" "$ns" "${OPERATOR}: create events in own ns"
        check "$sa" "$ns" "patch" "events" "$ns" "${OPERATOR}: patch events in own ns"

        # Core permissions that should always work
        check "$sa" "$ns" "get" "nodes" "cluster" "${OPERATOR}: get nodes"
        check "$sa" "$ns" "list" "nodes" "cluster" "${OPERATOR}: list nodes"

        echo ""
    done
done

if [ "$FOUND_ANY" = false ]; then
    echo "No Medik8s operator ServiceAccounts found."
    echo "Deploy operators first with 'make dev-deploy'."
    exit 0
fi

echo "=== Results ==="
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "RBAC mismatches detected. These are masked by OLM but exposed in"
    echo "non-OLM deployments (make deploy, kustomize)."
    echo ""
    echo "See: https://redhat.atlassian.net/browse/RHWA-1623"
    exit 1
fi

echo "All RBAC checks passed."
