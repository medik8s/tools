#!/usr/bin/env bash
################################################################################
# Remove RHWA operators (NHC, SNR, NMO, MDR, FAR) from all namespaces.
# Also deletes OLM v0 leftover ClusterRoles that block OLM v1 ClusterExtension
# (metrics-reader and *-ext-remediation roles).
#
# Options:
#   --only LIST              Remove only these operators (comma-separated: nhc,snr,nmo,mdr,far). Default: all.
#   --kubeconfig-from HOST   Download kubeconfig from remote host via SSH (defaults to root@).
#   --kubeconfig-path PATH   Remote kubeconfig path when using --kubeconfig-from (default: /root/.kube/config).
#
# Usage:
#   ./helper_scripts/remove_rhwa_operators.sh
#   ./helper_scripts/remove_rhwa_operators.sh --only far
#   ./helper_scripts/remove_rhwa_operators.sh --only nhc,snr
#   ./helper_scripts/remove_rhwa_operators.sh --kubeconfig-from my-bastion.example.com
#
# Requires on PATH: oc
################################################################################

set -euo pipefail

_kubeconfig_tmp=""
_rhwa_cleanup() {
  rm -f "${_kubeconfig_tmp}"
}
trap _rhwa_cleanup EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NHC_PKG="node-healthcheck-operator"
SNR_PKG="self-node-remediation"
NMO_PKG="node-maintenance-operator"
MDR_PKG="machine-deletion-remediation"
FAR_PKG="fence-agents-remediation"
ALL_OPERATORS=("$NHC_PKG" "$SNR_PKG" "$NMO_PKG" "$MDR_PKG" "$FAR_PKG")
ONLY_LIST=""
KUBECONFIG_FROM=""
KUBECONFIG_REMOTE_PATH="/root/.kube/config"

only_to_pkg() {
  case "$1" in
    nhc) echo "$NHC_PKG" ;;
    snr) echo "$SNR_PKG" ;;
    nmo) echo "$NMO_PKG" ;;
    mdr) echo "$MDR_PKG" ;;
    far) echo "$FAR_PKG" ;;
    *) echo "" ;;
  esac
}

rhwa_op_to_clusterextension() {
  case "$1" in
    "$NHC_PKG") echo "node-healthcheck-operator" ;;
    "$FAR_PKG") echo "fence-agents-remediation" ;;
    "$SNR_PKG") echo "self-node-remediation" ;;
    "$MDR_PKG") echo "machine-deletion-remediation" ;;
    "$NMO_PKG") echo "node-maintenance-operator" ;;
    *) echo "" ;;
  esac
}

rhwa_op_to_crd_group() {
  case "$1" in
    "$NHC_PKG") echo "remediation.medik8s.io" ;;
    "$FAR_PKG") echo "fence-agents-remediation.medik8s.io" ;;
    "$SNR_PKG") echo "self-node-remediation.medik8s.io" ;;
    "$MDR_PKG") echo "machine-deletion-remediation.medik8s.io" ;;
    "$NMO_PKG") echo "nodemaintenance.medik8s.io" ;;
    *) echo "" ;;
  esac
}

rhwa_add_stale_clusterroles_for_op() {
  local OP="$1"
  case "$OP" in
    "$MDR_PKG")
      rhwa_add_stale_clusterrole "machine-deletion-remediation-metrics-reader"
      rhwa_add_stale_clusterrole "machine-deletion-remediation-machine-deletion-remediation-ext-remediation"
      ;;
    "$FAR_PKG")
      rhwa_add_stale_clusterrole "fence-agents-remediation-metrics-reader"
      rhwa_add_stale_clusterrole "fence-agents-remediation-ext-remediation"
      ;;
    "$NHC_PKG")
      rhwa_add_stale_clusterrole "node-healthcheck-metrics-reader"
      ;;
    "$SNR_PKG")
      rhwa_add_stale_clusterrole "self-node-remediation-metrics-reader"
      rhwa_add_stale_clusterrole "self-node-remediation-ext-remediation"
      ;;
    "$NMO_PKG")
      rhwa_add_stale_clusterrole "node-maintenance-operator-metrics-reader"
      ;;
  esac
}

declare -A rhwa_stale_clusterrole_seen=()
rhwa_add_stale_clusterrole() {
  local cr="$1"
  [[ -z "$cr" ]] && return
  [[ -n "${rhwa_stale_clusterrole_seen[$cr]:-}" ]] && return
  rhwa_stale_clusterrole_seen[$cr]=1
  if oc get clusterrole "$cr" &>/dev/null; then
    oc delete clusterrole "$cr" --wait=true --timeout=45s 2>/dev/null && echo "  Deleted ClusterRole $cr" || \
      echo -e "  ${RED}Failed to delete ClusterRole $cr${NC}" >&2
  fi
}

usage() {
  sed -n '2,16p' "$0" | sed 's/^#   /  /' | sed 's/^# //'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY_LIST="$2"; shift 2 ;;
    --kubeconfig-from) KUBECONFIG_FROM="$2"; shift 2 ;;
    --kubeconfig-path) KUBECONFIG_REMOTE_PATH="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo -e "${RED}Unknown option: $1${NC}" >&2; usage ;;
  esac
done

if [[ -n "${ONLY_LIST:-}" ]]; then
  OPERATORS=()
  while IFS= read -r short; do
    short=$(echo "$short" | tr -d ' ')
    [[ -z "$short" ]] && continue
    pkg=$(only_to_pkg "$short")
    if [[ -n "$pkg" ]]; then
      OPERATORS+=("$pkg")
    else
      echo -e "${RED}Unknown operator in --only: $short (use: nhc,snr,nmo,mdr,far)${NC}" >&2
      exit 1
    fi
  done < <(echo "$ONLY_LIST" | tr ',' '\n')
  [[ ${#OPERATORS[@]} -eq 0 ]] && echo -e "${RED}--only must list at least one operator (nhc,snr,nmo,mdr,far)${NC}" >&2 && exit 1
else
  OPERATORS=("${ALL_OPERATORS[@]}")
fi

# Optional: fetch kubeconfig from remote host via SSH (defaults to root@).
# StrictHostKeyChecking=accept-new is intentional for QE lab hosts — a MITM on first
# connect could intercept the kubeconfig; do not use this on untrusted networks.
if [[ -n "${KUBECONFIG_FROM:-}" ]]; then
  _ssh_target="$KUBECONFIG_FROM"
  if [[ "$_ssh_target" != *"@"* ]]; then
    _ssh_target="root@${_ssh_target}"
  fi
  _kubeconfig_tmp=$(mktemp --suffix=.kubeconfig.rhwa.XXXXXX)
  echo -e "${GREEN}Downloading kubeconfig from ${_ssh_target}:${KUBECONFIG_REMOTE_PATH}${NC}"
  if ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$_ssh_target" cat "$KUBECONFIG_REMOTE_PATH" > "$_kubeconfig_tmp"; then
    echo -e "${RED}Failed to get kubeconfig from ${_ssh_target}. Ensure SSH key or password access for root.${NC}" >&2
    exit 1
  fi
  export KUBECONFIG="$_kubeconfig_tmp"
  echo -e "${GREEN}Using KUBECONFIG=$KUBECONFIG${NC}"
fi

echo -e "${YELLOW}Checking cluster connection...${NC}"
if ! oc whoami &>/dev/null; then
  echo -e "${RED}Not logged in. Run: oc login --token=... --server=...${NC}" >&2
  exit 1
fi
echo -e "${GREEN}Connected to: $(oc whoami --show-server)${NC}"
echo -e "  Removing operators: ${OPERATORS[*]}\n"

echo -e "${YELLOW}Finding and removing RHWA Subscriptions (single list)...${NC}"
subs_raw=$(oc get subscription -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PACKAGE:.spec.name --no-headers 2>/dev/null || true)
while read -r ns name pkg; do
  [[ -z "$pkg" ]] && continue
  for OP in "${OPERATORS[@]}"; do
    if [[ "$pkg" == "$OP" ]]; then
      if err=$(oc delete subscription "$name" -n "$ns" --ignore-not-found --timeout=45s 2>&1); then
        echo "  Deleted subscription $name in $ns"
      else
        echo -e "  ${RED}Failed to delete subscription $name in $ns: ${err}${NC}" >&2
      fi
      break
    fi
  done
done <<< "$subs_raw"

echo -e "\n${YELLOW}Finding and removing RHWA CSVs (batched by namespace)...${NC}"
csvs_raw=$(oc get csv -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
declare -A ns_csvs
while read -r ns name; do
  [[ -z "$name" ]] && continue
  for OP in "${OPERATORS[@]}"; do
    case "$name" in
      ${OP}.*)
        ns_csvs[$ns]="${ns_csvs[$ns]:+${ns_csvs[$ns]} }$name"
        break
        ;;
    esac
  done
done <<< "$csvs_raw"
for ns in "${!ns_csvs[@]}"; do
  names="${ns_csvs[$ns]}"
  if oc delete csv $names -n "$ns" --ignore-not-found --timeout=90s 2>/dev/null; then
    echo "  Deleted $(echo "$names" | wc -w) CSVs in $ns"
  else
    for name in $names; do
      if ! oc delete csv "$name" -n "$ns" --ignore-not-found --timeout=60s 2>/dev/null; then
        oc patch csv "$name" -n "$ns" --type=json -p '[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null
        oc delete csv "$name" -n "$ns" --ignore-not-found --timeout=60s 2>/dev/null && echo "  Deleted csv $name in $ns (after finalizers)" || echo -e "  ${RED}Failed csv $name in $ns${NC}" >&2
      fi
    done
  fi
done

echo -e "\n${YELLOW}Removing RHWA ClusterExtensions (if present)...${NC}"
ext_names=()
for OP in "${OPERATORS[@]}"; do
  en=$(rhwa_op_to_clusterextension "$OP")
  [[ -n "$en" ]] && ext_names+=("$en")
done
ext_list=$(oc get clusterextension -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null || true)
while read -r ext_name; do
  [[ -z "$ext_name" ]] && continue
  for en in "${ext_names[@]}"; do
    if [[ "$ext_name" == "$en" ]]; then
      oc delete clusterextension "$ext_name" --ignore-not-found --timeout=30s 2>/dev/null && echo "  Deleted clusterextension $ext_name" || true
      break
    fi
  done
done <<< "$ext_list"

echo -e "\n${YELLOW}Removing stale OLM v0 ClusterRoles for selected operators (if present)...${NC}"
for OP in "${OPERATORS[@]}"; do
  rhwa_add_stale_clusterroles_for_op "$OP"
done

CRD_GROUPS=()
for OP in "${OPERATORS[@]}"; do
  g=$(rhwa_op_to_crd_group "$OP")
  [[ -n "$g" ]] && CRD_GROUPS+=("$g")
done

echo -e "\n${YELLOW}Deleting RHWA custom resources in all namespaces...${NC}"
# OperatorGroup is OLM v0 only — shared by all RHWA Subscriptions in this namespace.
# Only delete when removing all operators to avoid breaking remaining OLM v0 installs.
if [[ ${#OPERATORS[@]} -eq ${#ALL_OPERATORS[@]} ]]; then
  echo -e "${YELLOW}Removing OperatorGroup in openshift-workload-availability (if present)...${NC}"
  oc delete operatorgroup workload-availability-operator-group -n openshift-workload-availability --ignore-not-found --timeout=30s 2>/dev/null && echo "  Deleted OperatorGroup workload-availability-operator-group" || true
else
  echo "  Skipping OperatorGroup deletion (partial removal via --only)."
fi

for group in "${CRD_GROUPS[@]}"; do
  crds=$(oc get crd -o jsonpath="{range .items[?(@.spec.group==\"$group\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null || true)
  for crd in $crds; do
    [[ -z "$crd" ]] && continue
    short=$(echo "$crd" | cut -d. -f1)
    cr_rows=$(oc get "$short" -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null || true)
    if [[ -n "$cr_rows" ]]; then
      deleted=0
      while read -r cr_ns cr_name; do
        [[ -z "$cr_name" ]] && continue
        if oc delete "$short" "$cr_name" -n "$cr_ns" --ignore-not-found --timeout=60s 2>/dev/null; then
          deleted=$((deleted + 1))
        fi
      done <<< "$cr_rows"
      [[ $deleted -gt 0 ]] && echo "  Deleted $deleted $short instance(s)"
    fi
  done
done

echo -e "\n${YELLOW}Deleting RHWA CRDs...${NC}"
for group in "${CRD_GROUPS[@]}"; do
  for crd in $(oc get crd -o jsonpath="{range .items[?(@.spec.group==\"$group\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null); do
    [[ -z "$crd" ]] && continue
    oc delete crd "$crd" --ignore-not-found --timeout=120s 2>/dev/null && echo "  Deleted CRD $crd" || true
  done
done

echo -e "\n${YELLOW}Checking for remaining resources...${NC}"
subs_all=$(oc get subscription -A --no-headers 2>/dev/null || true)
for OP in "${OPERATORS[@]}"; do
  subs=$(echo "$subs_all" | grep -E "\s+${OP}\s+" || true)
  [[ -n "$subs" ]] && echo -e "${YELLOW}  Remaining subscriptions for $OP:${NC}" && echo "$subs"
done
csvs_all=$(oc get csv -A --no-headers 2>/dev/null || true)
for OP in "${OPERATORS[@]}"; do
  csvs=$(echo "$csvs_all" | grep -E "${OP}\." || true)
  [[ -n "$csvs" ]] && echo -e "${YELLOW}  Remaining CSVs for $OP:${NC}" && echo "$csvs"
done
crd_list=$(oc get crd --no-headers 2>/dev/null || true)
for g in "${CRD_GROUPS[@]}"; do
  match=$(echo "$crd_list" | grep "$g" || true)
  [[ -n "$match" ]] && echo -e "${YELLOW}  Remaining RHWA CRDs ($g):${NC}" && echo "$match"
done

echo -e "\n${GREEN}Done. Selected RHWA operators removed (subscriptions, CSVs, ClusterExtensions, stale ClusterRoles, CRs, CRDs).${NC}"
