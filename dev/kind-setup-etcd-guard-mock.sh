#!/usr/bin/env bash
# Provisions a mock openshift-etcd Deployment and PDB in Kind clusters
# for control-plane quorum validation testing (NMO / SNR).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dev/common.sh
source "${SCRIPT_DIR}/common.sh"

echo "=== Provisioning mock etcd-guard Deployment and PDB (openshift-etcd) ==="

"${KUBECTL}" create namespace openshift-etcd --dry-run=client -o yaml | "${KUBECTL}" apply -f -

EXPECTED_CP=$("${KUBECTL}" get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l | tr -d ' ')
EXPECTED_CP=${EXPECTED_CP:-1}

# PDB minAvailable for etcd quorum: N - 1 (allows 1 CP node disruption)
if [ "${EXPECTED_CP}" -gt 1 ]; then
  MIN_AVAILABLE=$(( EXPECTED_CP - 1 ))
else
  MIN_AVAILABLE=1
fi

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
        image: registry.k8s.io/pause:3.9
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

echo "=== Waiting for PDB allowed disruptions to equal 1 ==="
for _ in {1..30}; do
  DISRUPTIONS=$("${KUBECTL}" get pdb/etcd-guard-pdb -n openshift-etcd -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo "0")
  if [ "${DISRUPTIONS}" -ge 1 ]; then
    break
  fi
  sleep 1
done

echo "=== Verifying etcd-guard pod parity with control-plane nodes ==="
RAW_READY=$("${KUBECTL}" get deployment/etcd-guard -n openshift-etcd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
READY_PODS=${RAW_READY:-0}
RAW_DISRUPTIONS=$("${KUBECTL}" get pdb/etcd-guard-pdb -n openshift-etcd -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo "0")
DISRUPTIONS=${RAW_DISRUPTIONS:-0}

echo "Control-plane nodes: ${EXPECTED_CP}, Ready etcd-guard pods: ${READY_PODS}, Allowed disruptions: ${DISRUPTIONS}"

if [ "${EXPECTED_CP}" -eq "${READY_PODS}" ] && [ "${EXPECTED_CP}" -ge 1 ] && [ "${DISRUPTIONS}" -eq 1 ]; then
  echo "✅ SUCCESS: etcd-guard Deployment and PDB verified on all control-plane nodes."
else
  echo "❌ ERROR: etcd-guard pod count (${READY_PODS}) or PDB disruptions (${DISRUPTIONS}) does not meet HA requirements!" >&2
  exit 1
fi
