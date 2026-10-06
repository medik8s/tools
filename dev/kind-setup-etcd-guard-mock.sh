#!/usr/bin/env bash
# Provisions a mock openshift-etcd Deployment and PDB in Kind clusters
# for control-plane quorum validation testing (NMO / SNR).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dev/common.sh
source "${SCRIPT_DIR}/common.sh"

echo "=== Provisioning mock etcd-guard Deployment and PDB (openshift-etcd) ==="

ETCD_GUARD_IMAGE="${ETCD_GUARD_IMAGE:-registry.k8s.io/pause:3.9}"

EXPECTED_CP=$("${KUBECTL}" get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${EXPECTED_CP:-0}" -lt 1 ]; then
  echo "❌ ERROR: No control-plane nodes found (label node-role.kubernetes.io/control-plane)." >&2
  exit 1
fi

# PDB minAvailable for etcd quorum: N - 1 (allows 1 CP node disruption)
if [ "${EXPECTED_CP}" -gt 1 ]; then
  MIN_AVAILABLE=$(( EXPECTED_CP - 1 ))
else
  MIN_AVAILABLE=1
fi

# Voluntary evictions the PDB permits: 0 on a single control plane (the sole
# guard must not be evictable), 1 on a 3 control-plane HA cluster.
EXPECTED_DISRUPTIONS=$(( EXPECTED_CP - MIN_AVAILABLE ))

"${KUBECTL}" create namespace openshift-etcd --dry-run=client -o yaml | "${KUBECTL}" apply -f -

"${KUBECTL}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: etcd-guard
  namespace: openshift-etcd
spec:
  replicas: ${EXPECTED_CP}
  selector:
    matchLabels:
      app: etcd-guard
  template:
    metadata:
      labels:
        app: etcd-guard
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - etcd-guard
            topologyKey: kubernetes.io/hostname
      containers:
      - name: pause
        image: ${ETCD_GUARD_IMAGE}
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: etcd-guard-pdb
  namespace: openshift-etcd
spec:
  minAvailable: ${MIN_AVAILABLE}
  selector:
    matchLabels:
      app: etcd-guard
EOF

echo "=== Waiting for etcd-guard Deployment rollout ==="
"${KUBECTL}" rollout status deployment/etcd-guard -n openshift-etcd --timeout=120s

echo "=== Waiting for PDB allowed disruptions to equal ${EXPECTED_DISRUPTIONS} ==="
DISRUPTIONS_READY=false
for _ in {1..30}; do
  RAW_DISRUPTIONS=$("${KUBECTL}" get pdb/etcd-guard-pdb -n openshift-etcd -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo "")
  # An empty value means the PDB controller has not published a status yet.
  if [ -n "${RAW_DISRUPTIONS}" ] && [ "${RAW_DISRUPTIONS}" -eq "${EXPECTED_DISRUPTIONS}" ]; then
    DISRUPTIONS_READY=true
    break
  fi
  sleep 1
done
if [ "${DISRUPTIONS_READY}" != true ]; then
  echo "WARN: PDB disruptionsAllowed is still '${RAW_DISRUPTIONS:-<unset>}' (expected ${EXPECTED_DISRUPTIONS}) after 30s" >&2
fi

echo "=== Verifying etcd-guard pod parity with control-plane nodes ==="
RAW_READY=$("${KUBECTL}" get deployment/etcd-guard -n openshift-etcd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
READY_PODS=${RAW_READY:-0}
RAW_DISRUPTIONS=$("${KUBECTL}" get pdb/etcd-guard-pdb -n openshift-etcd -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo "0")
DISRUPTIONS=${RAW_DISRUPTIONS:-0}

echo "Control-plane nodes: ${EXPECTED_CP}, Ready etcd-guard pods: ${READY_PODS}, Allowed disruptions: ${DISRUPTIONS} (expected ${EXPECTED_DISRUPTIONS})"

if [ "${EXPECTED_CP}" -eq "${READY_PODS}" ] && [ "${DISRUPTIONS}" -eq "${EXPECTED_DISRUPTIONS}" ]; then
  echo "✅ SUCCESS: etcd-guard Deployment and PDB verified on all control-plane nodes."
else
  echo "❌ ERROR: etcd-guard pod count (${READY_PODS}) does not match control-plane nodes (${EXPECTED_CP}), or PDB disruptions (${DISRUPTIONS}) does not equal the expected ${EXPECTED_DISRUPTIONS}!" >&2
  exit 1
fi
