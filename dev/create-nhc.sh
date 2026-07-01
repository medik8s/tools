#!/bin/bash
# Creates a NodeHealthCheck CR that references SNR for remediation.
# Usage: create-nhc.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Check if the NHC CRD exists
if ! ${KUBECTL} get crd nodehealthchecks.remediation.medik8s.io &>/dev/null; then
    echo "Error: NodeHealthCheck CRD not found. Deploy NHC first (make dev-deploy from the NHC directory)."
    exit 1
fi

# Find the SNR template namespace
SNR_NS=$(${KUBECTL} get selfnoderemediationtemplate -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | head -1)
SNR_TEMPLATE=$(${KUBECTL} get selfnoderemediationtemplate -A --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)

if [ -z "${SNR_NS}" ] || [ -z "${SNR_TEMPLATE}" ]; then
    echo "Error: No SelfNodeRemediationTemplate found. Deploy SNR first (make dev-deploy from the SNR directory)."
    exit 1
fi

echo "Creating NodeHealthCheck CR referencing ${SNR_TEMPLATE} in ${SNR_NS}..."

${KUBECTL} apply -f - <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: nhc-worker-default
spec:
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
  minHealthy: "51%"
  unhealthyConditions:
    - type: Ready
      status: "False"
      duration: 30s
    - type: Ready
      status: Unknown
      duration: 30s
  remediationTemplate:
    apiVersion: self-node-remediation.medik8s.io/v1alpha1
    kind: SelfNodeRemediationTemplate
    name: ${SNR_TEMPLATE}
    namespace: ${SNR_NS}
EOF

echo "NodeHealthCheck 'nhc-worker-default' created."
echo ""
echo "  Watches workers for Ready=False/Unknown for 30s, then triggers SNR."
echo "  Production uses 300s; 30s is for faster dev testing."
