#!/usr/bin/env bash
################################################################################
# Install all 6 RHWA operators: NHC, SNR, NMO, MDR, FAR, SBR.
#
# Options:
#   --channel CHANNEL     Subscription channel (default: stable)
#   --catsrc NAME         CatalogSource name (default: redhat-operators)
#   --catsrc-ns NS        CatalogSource namespace (default: openshift-marketplace)
#   --namespace NS        Install operators into NS (default: openshift-workload-availability)
#   --disable-nhc-plugin   Do not enable NHC console plugin (enabled by default)
#   --approval Manual|Automatic  InstallPlan approval (default: Automatic)
#   --olm v0|v1           OLM version: v0 uses Subscriptions (default), v1 uses ClusterExtension
#   --only LIST           Install only these operators (comma-separated: nhc,snr,nmo,mdr,far,sbr). Default: all.
#   --create-idms         Wait for --catsrc to be READY, generate IDMS from latest catalog versions, apply it, then install
#   --wait                Wait for all CSVs to succeed (default: true)
#   --no-wait             Skip waiting for CSVs
#   --kubeconfig-from HOST (optional) Download kubeconfig from remote host via SSH (user: root).
#                          Exports KUBECONFIG for this run.
#   --kubeconfig-path PATH (optional) Remote path to kubeconfig when using --kubeconfig-from (default: /root/.kube/config).
#
# Environment:
#   NHC_CONSOLE_PLUGIN_NAME  ConsolePlugin.metadata.name (default: node-remediation-console-plugin)
#   NHC_CONSOLE_PLUGIN_WAIT  Seconds to wait for that CR after CSV install (default: 300)
#
# Usage:
#   ./scripts/install_rhwa_operators.sh
#   ./scripts/install_rhwa_operators.sh --only snr,nhc
#   ./scripts/install_rhwa_operators.sh --channel stable-4.12 --catsrc redhat-operators
#   ./scripts/install_rhwa_operators.sh --kubeconfig-from my-bastion.example.com
#   ./scripts/install_rhwa_operators.sh --kubeconfig-from root@192.168.1.10 --only nhc
#   ./scripts/install_rhwa_operators.sh --kubeconfig-from bastion --kubeconfig-path /home/kni/clusterconfigs/auth/kubeconfig
#   ./scripts/install_rhwa_operators.sh --catsrc rhwa-konflux-test-1141449 --create-idms
#
# Requires scripts/lib/rhwa_utils.sh (sourced from the same directory). Clone or copy the
#   full scripts/ tree. --create-idms embeds the Konflux mirror map.
#   Requires on PATH: oc, jq. For --create-idms with a custom catalog
#   while the same packages also exist in redhat/community catalogs, install opm so the script can
#   opm render the CatalogSource index image and read bundle relatedImages (PackageManifest is ambiguous).
#
#   then: ./scripts/install_rhwa_operators.sh --catsrc rhwa-operators --create-idms
#   IDMS YAML is written next to this script: <script-dir>/idms/
################################################################################

set -euo pipefail

_kubeconfig_tmp=""
_rhwa_exit_code=0
_rhwa_install_started=false
_rhwa_cleanup() {
  local _trap_rc=$?
  [[ "$_rhwa_install_started" == "true" ]] && _rhwa_remove_duplicate_subs || true
  rm -f "${_kubeconfig_tmp}"
  exit $(( _rhwa_exit_code > 0 ? _rhwa_exit_code : _trap_rc ))
}
trap _rhwa_cleanup EXIT

_rhwa_remove_duplicate_subs() {
  [[ -z "${NS:-}" ]] && return 0
  [[ -v ALL_PACKAGES ]] || return 0
  [[ ${#ALL_PACKAGES[@]} -eq 0 ]] && return 0
  oc whoami &>/dev/null || return 0
  echo -e "\n${YELLOW}Removing duplicate subscriptions (keep only <package>-operator)...${NC}"
  local _local_subs_tmp
  _local_subs_tmp=$(mktemp)
  for _pass in 1 2; do
    [[ $_pass -eq 2 ]] && sleep 3
    oc get subscription -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.name}{"\n"}{end}' 2>/dev/null > "$_local_subs_tmp" || true
    while read -r sub_meta_name spec_name; do
      [[ -z "$sub_meta_name" ]] && continue
      for pkg in "${ALL_PACKAGES[@]}"; do
        if [[ "$spec_name" == "$pkg" ]]; then
          canonical="${pkg}-operator"
          if [[ "$sub_meta_name" != "$canonical" ]]; then
            oc delete subscription "$sub_meta_name" -n "$NS" --ignore-not-found --timeout=30s 2>/dev/null && echo "  Deleted duplicate subscription: $sub_meta_name" || true
          fi
          break
        fi
      done
    done < "$_local_subs_tmp" 2>/dev/null || true
  done
  rm -f "$_local_subs_tmp"
}

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' NC=''
fi

NS=openshift-workload-availability
CHANNEL=stable
CATSRC=redhat-operators
CATSRC_NS=openshift-marketplace
ENABLE_NHC_PLUGIN=true
APPROVAL=Automatic
WAIT=true
CREATE_IDMS=false
OLM_VERSION=v0
IDMS_WAIT_TIMEOUT=600
KUBECONFIG_FROM=""
KUBECONFIG_REMOTE_PATH="/root/.kube/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rhwa_utils.sh
source "${SCRIPT_DIR}/lib/rhwa_utils.sh"

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }
# NHC console plugin name (ConsolePlugin.metadata.name created by NHC operator)
NHC_CONSOLE_PLUGIN_NAME="${NHC_CONSOLE_PLUGIN_NAME:-node-remediation-console-plugin}"
NHC_CONSOLE_PLUGIN_WAIT="${NHC_CONSOLE_PLUGIN_WAIT:-300}"

# Short name -> OLM package name
NHC_PKG="node-healthcheck-operator"
SNR_PKG="self-node-remediation"
NMO_PKG="node-maintenance-operator"
MDR_PKG="machine-deletion-remediation"
FAR_PKG="fence-agents-remediation"
SBR_PKG="storage-based-remediation"
ALL_PACKAGES=("$NHC_PKG" "$SNR_PKG" "$NMO_PKG" "$MDR_PKG" "$FAR_PKG" "$SBR_PKG")
ONLY_LIST=""

# Map short names (nhc,snr,nmo,mdr,far,sbr) to package name
only_to_pkg() {
  case "$1" in
    nhc) echo "$NHC_PKG" ;;
    snr) echo "$SNR_PKG" ;;
    nmo) echo "$NMO_PKG" ;;
    mdr) echo "$MDR_PKG" ;;
    far) echo "$FAR_PKG" ;;
    sbr) echo "$SBR_PKG" ;;
    *) echo "" ;;
  esac
}

# Konflux quay mirror map for --create-idms. Update lib/rhwa_idms_map.json when images change.
rhwa_embedded_idms_map_json() {
  cat "${SCRIPT_DIR}/lib/rhwa_idms_map.json"
}

rhwa_idms_version_suffix() {
  local ver="$1"
  echo "$(echo "$ver" | cut -d. -f1)-$(echo "$ver" | cut -d. -f2)"
}

rhwa_idms_image_repo_path() {
  local img="${1%%@*}"
  img="${img#*/}"
  echo "$img"
}

# PackageManifest for a package can point at redhat-operators when the same package exists in
# multiple catalogs. Prefer list filtered by labels propagated from CatalogSource (catalog, catalog-namespace).
rhwa_get_packagemanifest_json_for_catalog() {
  local pkg="$1" catsrc="$2" catsrc_ns="$3"
  local pm_list_json item

  pm_list_json=$(oc get packagemanifest -n openshift-marketplace \
    -l "catalog=${catsrc},catalog-namespace=${catsrc_ns}" \
    -o json 2>/dev/null || true)
  if [[ -n "$pm_list_json" ]] && echo "$pm_list_json" | jq -e '.items | length > 0' >/dev/null 2>&1; then
    item=$(echo "$pm_list_json" | jq -c --arg pkg "$pkg" '[.items[]? | select(.metadata.name==$pkg)] | .[0] // empty')
    if [[ -n "$item" && "$item" != "null" ]]; then
      echo "$item"
      return 0
    fi
  fi

  pm_list_json=$(oc get packagemanifest -n openshift-marketplace -l "catalog=${catsrc}" -o json 2>/dev/null || true)
  if [[ -n "$pm_list_json" ]] && echo "$pm_list_json" | jq -e '.items | length > 0' >/dev/null 2>&1; then
    item=$(echo "$pm_list_json" | jq -c --arg pkg "$pkg" --arg cns "$catsrc_ns" \
      '[.items[]? | select(.metadata.name==$pkg and ((.status.catalogSourceNamespace // "")==$cns))] | .[0] // empty')
    if [[ -n "$item" && "$item" != "null" ]]; then
      echo "$item"
      return 0
    fi
  fi

  oc get packagemanifest "$pkg" -n openshift-marketplace -o json 2>/dev/null || true
}

# Emit one image reference per line from a CSV-like object (currentCSVDesc or olm.bundle).
rhwa_idms_related_image_refs() {
  local blob="$1"
  echo "$blob" | jq -r '
    (if type == "string" then (try fromjson catch empty) else . end)
    | .relatedImages[]?
    | if type == "string" then .
      elif type == "object" then (.image // .Image // .value // empty)
      else empty end
    | select(type == "string" and length > 0)
  '
}

# If currentCSVDesc is a JSON-encoded string, decode to object.
rhwa_idms_normalize_csv_desc() {
  local d="$1"
  echo "$d" | jq -c 'if type == "string" then (try fromjson catch .) else . end'
}

# When PackageManifest points at another catalog (same package in redhat + custom index),
# resolve the bundle from the index image via opm render (requires opm on PATH + registry pull).
rhwa_best_olm_bundle_from_opm() {
  local idx="$1" pkg="$2"
  [[ -n "$idx" ]] && command -v opm &>/dev/null || { echo ""; return 0; }
  opm render "$idx" 2>/dev/null | jq -s --arg pkg "$pkg" -c '
    ([ .[] | select(type=="object" and .schema=="olm.bundle" and (.package==$pkg)) ]
     | if length == 0 then empty
       else sort_by(.name) | last
       end)
  '
}

rhwa_version_from_bundle_name() {
  echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true
}

# Wait for catalog READY, build IDMS from PackageManifests, write file, oc apply.
# Args: catsrc catsrc_ns channel output_file wait_timeout_sec  package...
rhwa_create_idms_from_catsrc() {
  local catsrc="$1" catsrc_ns="$2" channel="$3" output="$4" wait_timeout="$5"
  shift 5
  local -a pkg_list=("$@")
  local map_json quay_prefix pm_json csv_desc version current_csv ver_suffix
  local repo_path repo_name map_entry component artifact mirror
  local -A mirror_entries=()
  local -A pkg_versions=()

  map_json=$(rhwa_embedded_idms_map_json)
  echo "$map_json" | jq -e . >/dev/null 2>&1 || {
    echo -e "${RED}Embedded IDMS map JSON is invalid${NC}" >&2
    return 1
  }
  quay_prefix=$(echo "$map_json" | jq -r '.quay_prefix')

  local idx_image
  idx_image=$(oc get catalogsource "$catsrc" -n "$catsrc_ns" -o jsonpath='{.spec.image}' 2>/dev/null || echo "")

  rhwa_wait_catsrc_ready "$catsrc" "$catsrc_ns" "$wait_timeout" || return 1
  echo -e "${GREEN}CatalogSource is READY.${NC}"

  local _pm_deadline=$(($(date +%s) + 120)) found
  while true; do
    found=$(oc get packagemanifest -n openshift-marketplace -o json 2>/dev/null | jq -r \
      --arg cs "$catsrc" --arg cns "$catsrc_ns" \
      '[.items[] | select(.status.catalogSource==$cs and .status.catalogSourceNamespace==$cns)] | length')
    if [[ "${found:-0}" -gt 0 ]]; then
      break
    fi
    if (( $(date +%s) > _pm_deadline )); then
      echo -e "${YELLOW}No PackageManifests for ${catsrc} yet; continuing with package list.${NC}"
      break
    fi
    sleep 5
  done

  local pkg
  for pkg in "${pkg_list[@]}"; do
    pkg=$(echo "$pkg" | tr -d ' ')
    [[ -n "$pkg" ]] || continue

    pm_json=$(rhwa_get_packagemanifest_json_for_catalog "$pkg" "$catsrc" "$catsrc_ns")
    if [[ -z "$pm_json" ]] || ! echo "$pm_json" | jq -e .metadata.name >/dev/null 2>&1; then
      echo -e "${YELLOW}PackageManifest ${pkg} not found for catalog ${catsrc}/${catsrc_ns}; trying opm render if available.${NC}"
    fi

    local cs_name cs_ns catalog_ok=false
    if [[ -n "$pm_json" ]] && echo "$pm_json" | jq -e .metadata.name >/dev/null 2>&1; then
      cs_name=$(echo "$pm_json" | jq -r '.status.catalogSource // ""')
      cs_ns=$(echo "$pm_json" | jq -r '.status.catalogSourceNamespace // ""')
      if [[ "$cs_name" == "$catsrc" && "$cs_ns" == "$catsrc_ns" ]]; then
        catalog_ok=true
      else
        echo -e "${YELLOW}${pkg}: PackageManifest status is ${cs_name}/${cs_ns} (expected ${catsrc}/${catsrc_ns}); will try opm render from index image.${NC}"
      fi
    fi

    csv_desc=""
    version=""
    current_csv=""
    ver_suffix=""

    if [[ "$catalog_ok" == "true" ]]; then
      csv_desc=$(echo "$pm_json" | jq -c --arg ch "$channel" \
        '.status.channels[]? | select(.name==$ch) | .currentCSVDesc' | head -1)
      [[ -z "$csv_desc" || "$csv_desc" == "null" ]] && csv_desc=""
      if [[ -n "$csv_desc" ]]; then
        csv_desc=$(rhwa_idms_normalize_csv_desc "$csv_desc")
        version=$(echo "$csv_desc" | jq -r '.version // ""')
        current_csv=$(echo "$pm_json" | jq -r \
          --arg ch "$channel" '.status.channels[] | select(.name==$ch) | .currentCSV')
        ver_suffix=$(rhwa_idms_version_suffix "$version")
      fi
    fi

    if [[ -z "$csv_desc" || "$csv_desc" == "null" ]] && [[ -n "$idx_image" ]] && command -v opm &>/dev/null; then
      local bundle_json bver bname
      bundle_json=$(rhwa_best_olm_bundle_from_opm "$idx_image" "$pkg")
      if [[ -n "$bundle_json" && "$bundle_json" != "null" ]]; then
        bname=$(echo "$bundle_json" | jq -r '.name // ""')
        bver=$(rhwa_version_from_bundle_name "$bname")
        [[ -z "$bver" ]] && bver=$(echo "$bundle_json" | jq -r '.properties[]? | select(.type=="olm.package") | .value.version // empty' | head -1)
        if [[ -n "$bver" ]]; then
          csv_desc="$bundle_json"
          version="$bver"
          current_csv="$bname"
          ver_suffix=$(rhwa_idms_version_suffix "$version")
          pkg_versions["$pkg"]="${version} (${current_csv}) via opm"
          echo -e "${GREEN}${pkg}: ${version} (${current_csv}) from opm render -> mirror suffix ${ver_suffix}${NC}"
        fi
      fi
    elif [[ -z "$csv_desc" || "$csv_desc" == "null" ]]; then
      echo -e "${YELLOW}${pkg}: channel ${channel} not in PackageManifest and opm unavailable or no index image; skipping.${NC}"
      continue
    fi

    if [[ -z "$csv_desc" || "$csv_desc" == "null" ]]; then
      echo -e "${YELLOW}${pkg}: could not resolve bundle; skipping.${NC}"
      continue
    fi

    if [[ "$catalog_ok" == "true" ]]; then
      pkg_versions["$pkg"]="${version} (${current_csv})"
      echo -e "${GREEN}${pkg}: ${version} (${current_csv}) -> mirror suffix ${ver_suffix}${NC}"
    fi

    local img_count=0
    while IFS= read -r img; do
      [[ -n "$img" ]] || continue
      img_count=$((img_count + 1))
      repo_path=$(rhwa_idms_image_repo_path "$img")
      repo_name="${repo_path#workload-availability/}"

      map_entry=$(echo "$map_json" | jq -c --arg repo "$repo_name" '.images[$repo] // empty')
      [[ -n "$map_entry" && "$map_entry" != "null" ]] || continue

      component=$(echo "$map_entry" | jq -r '.component')
      artifact=$(echo "$map_entry" | jq -r '.artifact')
      local source="registry.redhat.io/${repo_path}"
      mirror="${quay_prefix}/${component}/${artifact}-${ver_suffix}"
      mirror_entries["$source"]="$mirror"
    done < <(rhwa_idms_related_image_refs "$csv_desc")

    if [[ "$img_count" -eq 0 ]]; then
      echo -e "${YELLOW}${pkg}: no relatedImages parsed (check catalog bundle); skipping.${NC}"
    fi
  done

  if [[ ${#mirror_entries[@]} -eq 0 ]]; then
    echo -e "${RED}No IDMS mirror entries generated. Check channel ${channel}, index image, and install opm for multi-catalog clusters:${NC}" >&2
    echo -e "${RED}  https://github.com/operator-framework/operator-registry/releases${NC}" >&2
    return 1
  fi

  mkdir -p "$(dirname "$output")"
  local _mirrors_json='[]'
  local s
  for s in $(printf '%s\n' "${!mirror_entries[@]}" | sort); do
    _mirrors_json=$(echo "$_mirrors_json" | jq --arg src "$s" --arg mir "${mirror_entries[$s]}" \
      '. + [{"mirrors": [$mir], "source": $src}]')
  done
  # Intentionally same name as deploy_iib.sh IDMS — --create-idms supersedes it with live catalog data
  local _timestamp
  _timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg catsrc "$catsrc" \
    --arg ts "$_timestamp" \
    --arg channel "$channel" \
    --argjson mirrors "$_mirrors_json" \
    '{
      apiVersion: "config.openshift.io/v1",
      kind: "ImageDigestMirrorSet",
      metadata: {
        name: "rhwa-fbc-fips-image-mirror-set",
        labels: {"rhwa.redhat.com/generated-from-catalog": $catsrc},
        annotations: {
          "rhwa.redhat.com/generated-at": $ts,
          "rhwa.redhat.com/catalog-channel": $channel
        }
      },
      spec: {imageDigestMirrors: $mirrors}
    }' > "$output"

  echo -e "${GREEN}Wrote ImageDigestMirrorSet (${#mirror_entries[@]} entries): ${output}${NC}"
  for pkg in "${!pkg_versions[@]}"; do
    echo "  ${pkg}: ${pkg_versions[$pkg]}"
  done

  echo -e "${GREEN}Applying IDMS...${NC}"
  oc apply -f "$output"
  echo -e "${GREEN}Applied. Nodes will reconcile MachineConfig for registry mirrors (may take several minutes).${NC}"
}

usage() {
  sed -n '2,40p' "$0" | sed 's/^#   /  /' | sed 's/^# //'
  echo ""
  echo "  Defaults: channel=$CHANNEL, catsrc=$CATSRC, namespace=$NS, approval=$APPROVAL, nhc-plugin=enabled"
  echo "  --create-idms: wait for catalog READY, write <script-dir>/idms/imageDigestMirrorSet_<catsrc>.yaml, oc apply, then install"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --olm)
      [[ $# -lt 2 ]] && { echo -e "${RED}--olm requires a value (v0 or v1)${NC}" >&2; exit 1; }
      OLM_VERSION="$2"
      if [[ "$OLM_VERSION" != "v0" && "$OLM_VERSION" != "v1" ]]; then
        echo -e "${RED}--olm must be v0 or v1 (got: ${OLM_VERSION})${NC}" >&2; exit 1
      fi
      shift 2 ;;
    --channel)      [[ $# -lt 2 ]] && { echo -e "${RED}--channel requires a value${NC}" >&2; exit 1; }; CHANNEL="$2"; shift 2 ;;
    --catsrc)       [[ $# -lt 2 ]] && { echo -e "${RED}--catsrc requires a value${NC}" >&2; exit 1; }; CATSRC="$2"; shift 2 ;;
    --catsrc-ns)    [[ $# -lt 2 ]] && { echo -e "${RED}--catsrc-ns requires a value${NC}" >&2; exit 1; }; CATSRC_NS="$2"; shift 2 ;;
    --namespace)    [[ $# -lt 2 ]] && { echo -e "${RED}--namespace requires a value${NC}" >&2; exit 1; }; NS="$2"; shift 2 ;;
    --only)         [[ $# -lt 2 ]] && { echo -e "${RED}--only requires a value${NC}" >&2; exit 1; }; ONLY_LIST="$2"; shift 2 ;;
    --disable-nhc-plugin) ENABLE_NHC_PLUGIN=false; shift ;;
    --approval)     [[ $# -lt 2 ]] && { echo -e "${RED}--approval requires a value${NC}" >&2; exit 1; }; APPROVAL="$2"; shift 2 ;;
    --wait)         WAIT=true; shift ;;
    --no-wait)      WAIT=false; shift ;;
    --create-idms)  CREATE_IDMS=true; shift ;;
    --kubeconfig-from) [[ $# -lt 2 ]] && { echo -e "${RED}--kubeconfig-from requires a value${NC}" >&2; exit 1; }; KUBECONFIG_FROM="$2"; shift 2 ;;
    --kubeconfig-path) [[ $# -lt 2 ]] && { echo -e "${RED}--kubeconfig-path requires a value${NC}" >&2; exit 1; }; KUBECONFIG_REMOTE_PATH="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) echo -e "${RED}Unknown option: $1${NC}" >&2; usage ;;
  esac
done

# Build PACKAGES from --only (comma-separated: nhc,snr,nmo,mdr,far,sbr) or default all
if [[ -n "${ONLY_LIST:-}" ]]; then
  PACKAGES=()
  while IFS= read -r short; do
    short=$(echo "$short" | tr -d ' ')
    [[ -z "$short" ]] && continue
    pkg=$(only_to_pkg "$short")
    if [[ -n "$pkg" ]]; then
      PACKAGES+=("$pkg")
    else
      echo -e "${RED}Unknown operator in --only: $short (use: nhc,snr,nmo,mdr,far,sbr)${NC}" >&2
      exit 1
    fi
  done < <(echo "$ONLY_LIST" | tr ',' '\n')
  [[ ${#PACKAGES[@]} -eq 0 ]] && echo -e "${RED}--only must list at least one operator (nhc,snr,nmo,mdr,far,sbr)${NC}" >&2 && exit 1
else
  PACKAGES=("${ALL_PACKAGES[@]}")
fi

if [[ "$APPROVAL" != "Manual" && "$APPROVAL" != "Automatic" ]]; then
  echo -e "${RED}--approval must be Manual or Automatic${NC}" >&2
  exit 1
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

if ! oc whoami &>/dev/null; then
  echo -e "${RED}Not logged in. Run: oc login --token=... --server=...${NC}" >&2
  exit 1
fi

_rhwa_install_started=true
echo -e "${GREEN}Installing RHWA operators: ${PACKAGES[*]}${NC}"
echo "  channel: $CHANNEL, catalog: $CATSRC ($CATSRC_NS), namespace: $NS, approval: $APPROVAL"
echo "  enable NHC console plugin: $ENABLE_NHC_PLUGIN"
echo "  create IDMS from catalog: $CREATE_IDMS"
echo "  OLM version: $OLM_VERSION"
if [[ "$OLM_VERSION" == "v0" ]]; then
  echo "  If some CSVs never appear or stay Pending: OLM bundle unpack may be timing out. Increase timeout with:"
  echo "    oc patch deployment catalog-operator -n openshift-operator-lifecycle-manager --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--bundle-unpack-timeout\"},{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"30m\"}]'"
fi
echo ""

if [[ "$CREATE_IDMS" == "true" ]]; then
  if [[ "$OLM_VERSION" == "v1" ]]; then
    echo -e "${RED}--create-idms is not yet supported with --olm v1${NC}" >&2; exit 1
  fi
  if ! oc get "catalogsource/${CATSRC}" -n "${CATSRC_NS}" &>/dev/null; then
    echo -e "${RED}CatalogSource ${CATSRC} not found in ${CATSRC_NS}. Create it first (e.g. setup_clusterbot.sh).${NC}" >&2
    exit 1
  fi
  _idms_dir="${SCRIPT_DIR}/idms"
  mkdir -p "${_idms_dir}"
  _idms_file="${_idms_dir}/imageDigestMirrorSet_${CATSRC}.yaml"
  echo -e "${YELLOW}Catalog ${CATSRC} must be READY before IDMS generation and operator install.${NC}"
  rhwa_create_idms_from_catsrc "${CATSRC}" "${CATSRC_NS}" "${CHANNEL}" "${_idms_file}" "${IDMS_WAIT_TIMEOUT}" "${PACKAGES[@]}"
  echo -e "${GREEN}IDMS saved to ${_idms_file} and applied.${NC}"
  echo ""
fi

# Ensure namespace exists
if ! oc get ns "$NS" &>/dev/null; then
  echo -e "${YELLOW}Creating namespace $NS${NC}"
  oc create namespace "$NS"
fi

if [[ "$OLM_VERSION" == "v1" ]]; then
  # --- OLM v1: ClusterExtension + ServiceAccount + RBAC ---
  if ! oc api-resources --api-group=olm.operatorframework.io 2>/dev/null | grep -q ClusterExtension; then
    echo -e "${RED}OLM v1 CRDs not found on this cluster (ClusterExtension). OLM v1 requires OCP >= 4.18.${NC}" >&2
    exit 1
  fi

  # OCP 5.0+ prefixes default catalogs with "openshift-" (e.g. redhat-operators → openshift-redhat-operators).
  # Resolve the actual ClusterCatalog name for the label selector.
  V1_CATSRC="$CATSRC"
  if ! oc get clustercatalog "$V1_CATSRC" &>/dev/null; then
    if oc get clustercatalog "openshift-${CATSRC}" &>/dev/null; then
      V1_CATSRC="openshift-${CATSRC}"
      echo "  Resolved ClusterCatalog name: ${CATSRC} → ${V1_CATSRC}"
    else
      echo -e "${RED}ClusterCatalog '${CATSRC}' not found (also tried 'openshift-${CATSRC}').${NC}" >&2
      echo "  Available ClusterCatalogs:"
      oc get clustercatalog -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | sed 's/^/    /'
      exit 1
    fi
  fi

  # Create a ServiceAccount per operator with cluster-admin RBAC.
  # cluster-admin is intentional for QE/lab — deriving per-operator RBAC from CSVs is fragile.
  for pkg in "${PACKAGES[@]}"; do
    sa_name="${pkg}-installer"
    crb_name="${pkg}-installer-admin"

    if ! oc get sa "$sa_name" -n "$NS" &>/dev/null; then
      echo "  Creating ServiceAccount ${sa_name} in ${NS}"
      oc create serviceaccount "$sa_name" -n "$NS"
    else
      echo "  ServiceAccount ${sa_name} already exists"
    fi

    if ! oc get clusterrolebinding "$crb_name" &>/dev/null; then
      echo "  Creating ClusterRoleBinding ${crb_name} (cluster-admin)"
      jq -n --arg name "$crb_name" --arg sa "$sa_name" --arg ns "$NS" \
        '{apiVersion:"rbac.authorization.k8s.io/v1",kind:"ClusterRoleBinding",
          metadata:{name:$name},
          roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"ClusterRole",name:"cluster-admin"},
          subjects:[{kind:"ServiceAccount",name:$sa,namespace:$ns}]}' \
        | oc apply -f -
    else
      echo "  ClusterRoleBinding ${crb_name} already exists"
    fi
  done

  echo ""
  echo -e "${YELLOW}Creating ClusterExtensions...${NC}"
  for pkg in "${PACKAGES[@]}"; do
    ce_name="${pkg}"
    sa_name="${pkg}-installer"

    if oc get clusterextension "$ce_name" &>/dev/null; then
      echo "  ClusterExtension ${ce_name} already exists, skipping"
      continue
    fi

    echo "  Creating ClusterExtension for ${pkg} (channel: ${CHANNEL}, catalog: ${V1_CATSRC})"
    jq -n \
      --arg name "$ce_name" --arg ns "$NS" --arg sa "$sa_name" \
      --arg pkg "$pkg" --arg ch "$CHANNEL" --arg catsrc "$V1_CATSRC" \
      '{apiVersion:"olm.operatorframework.io/v1",kind:"ClusterExtension",
        metadata:{name:$name},
        spec:{namespace:$ns,serviceAccount:{name:$sa},
          source:{sourceType:"Catalog",
            catalog:{packageName:$pkg,channels:[$ch],
              selector:{matchLabels:{"olm.operatorframework.io/metadata.name":$catsrc}}}}}}' \
      | oc apply -f -
  done

  if [[ "$WAIT" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}Waiting for all ClusterExtensions to be Installed (timeout 15m each)...${NC}"
    for pkg in "${PACKAGES[@]}"; do
      ce_name="${pkg}"
      start_ts=$(date +%s)
      timeout_s=900
      while true; do
        installed=$(oc get clusterextension "$ce_name" \
          -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" "}{end}' 2>/dev/null || echo "")
        if echo "$installed" | grep -q 'Installed=True'; then
          echo -e "  ${GREEN}${ce_name}: Installed${NC}"
          break
        fi
        prog_msg=$(oc get clusterextension "$ce_name" \
          -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.message}{end}' 2>/dev/null || true)
        if echo "$installed" | grep -q 'Installed=False'; then
          fail_msg=$(oc get clusterextension "$ce_name" \
            -o jsonpath='{range .status.conditions[?(@.type=="Installed")]}{.message}{end}' 2>/dev/null || true)
          fail_reason=$(oc get clusterextension "$ce_name" \
            -o jsonpath='{range .status.conditions[?(@.type=="Installed")]}{.reason}{end}' 2>/dev/null || true)
          if [[ "$fail_msg" != "${_prev_fail_msg:-}" ]]; then
            echo -e "  ${RED}${ce_name}: Installed=False (${fail_reason}): ${fail_msg}${NC}" >&2
            _prev_fail_msg="$fail_msg"
          fi
          if [[ "$fail_reason" == "Failed" ]]; then
            echo -e "${RED}${ce_name}: terminal failure (${fail_reason}), not retrying${NC}" >&2
            exit 1
          fi
        fi
        if (( $(date +%s) - start_ts > timeout_s )); then
          echo -e "${RED}Timeout waiting for ClusterExtension ${ce_name}${NC}" >&2
          oc describe clusterextension "$ce_name" 2>/dev/null | tail -20 >&2 || true
          exit 1
        fi
        if [[ -n "$prog_msg" && "$prog_msg" != "${_prev_prog_msg:-}" ]]; then
          echo "    Progressing: ${prog_msg}"
          _prev_prog_msg="$prog_msg"
        fi
        sleep 10
      done
    done
    echo -e "${GREEN}All ClusterExtensions Installed.${NC}"
  fi

  echo ""
  echo -e "${GREEN}Done (OLM v1). Operators installed in namespace: $NS${NC}"
  echo "  Check: oc get clusterextension"
  echo "  Check: oc get pods -n $NS"
  echo "  To uninstall: delete ClusterExtensions, then their ServiceAccounts and ClusterRoleBindings:"
  echo "    oc delete clusterextension ${PACKAGES[*]}"
  echo "    oc delete clusterrolebinding $(printf '%s-installer-admin ' "${PACKAGES[@]}")"
  echo "    oc delete sa -n $NS $(printf '%s-installer ' "${PACKAGES[@]}")"

else
  # --- OLM v0: OperatorGroup + Subscriptions ---

  # OperatorGroup: match rhwa_testing_data.sh — metadata only, no spec.
  # OLM requires exactly one OperatorGroup per namespace; it may auto-create one (e.g. openshift-workload-availability-xxxx).
  # Keep only our canonical one so "found 2 operatorGroups, expected 1" does not block installs.
  og_name=workload-availability-operator-group
  for extra_og in $(oc get operatorgroup -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    if [[ -n "$extra_og" && "$extra_og" != "$og_name" ]]; then
      echo -e "${YELLOW}Removing extra OperatorGroup $extra_og (OLM allows only one per namespace)${NC}"
      oc delete operatorgroup "$extra_og" -n "$NS" --ignore-not-found --timeout=30s 2>/dev/null || true
    fi
  done
  if ! oc get operatorgroup "$og_name" -n "$NS" &>/dev/null; then
    echo -e "${YELLOW}Creating OperatorGroup in $NS${NC}"
    jq -n --arg name "$og_name" --arg ns "$NS" \
      '{apiVersion:"operators.coreos.com/v1",kind:"OperatorGroup",metadata:{name:$name,namespace:$ns}}' \
      | oc apply -f -
  fi

  # Yields e.g. nhc-operator-operator for pkgs ending in -operator — cosmetic, not worth renaming (breaks existing clusters)
  for pkg in "${PACKAGES[@]}"; do
    sub_name="${pkg}-operator"
    if oc get subscription "$sub_name" -n "$NS" &>/dev/null; then
      echo "  Subscription $sub_name already exists, patching channel to $CHANNEL"
      _sub_patch=$(jq -n --arg ch "$CHANNEL" '{"spec":{"channel":$ch}}')
      oc patch subscription "$sub_name" -n "$NS" --type=merge -p "$_sub_patch"
    else
      echo "  Creating Subscription for $pkg (channel: $CHANNEL)"
      _sub_json=$(jq -n \
        --arg name "$sub_name" \
        --arg ns "$NS" \
        --arg channel "$CHANNEL" \
        --arg approval "$APPROVAL" \
        --arg pkg "$pkg" \
        --arg catsrc "$CATSRC" \
        --arg catsrcNs "$CATSRC_NS" \
        '{
          apiVersion: "operators.coreos.com/v1alpha1",
          kind: "Subscription",
          metadata: {name: $name, namespace: $ns},
          spec: {channel: $channel, installPlanApproval: $approval, name: $pkg, source: $catsrc, sourceNamespace: $catsrcNs}
        }')
      echo "$_sub_json" | oc apply -f -
    fi
  done

  if [[ "$WAIT" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}Waiting for all operator CSVs to reach Succeeded (timeout 15m each)...${NC}"
    for pkg in "${PACKAGES[@]}"; do
      start_ts=$(date +%s)
      timeout_s=900
      while true; do
        csv_name=$(oc get csv -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E "^${pkg}\." | head -1 || true)
        if [[ -n "${csv_name:-}" ]]; then
          phase=$(oc get csv -n "$NS" "$csv_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
          if [[ "$phase" == "Succeeded" ]]; then
            echo "  $pkg: $csv_name (Succeeded)"
            break
          fi
          if [[ "$phase" == "Failed" ]]; then
            echo -e "  ${RED}$pkg: $csv_name phase=Failed${NC}" >&2
          fi
        fi
        if (( $(date +%s) - start_ts > timeout_s )); then
          echo -e "${RED}Timeout waiting for $pkg CSV${NC}" >&2
          exit 1
        fi
        sleep 5
      done
    done
    echo -e "${GREEN}All operator CSVs Succeeded.${NC}"
  fi

  # Optionally enable NHC console plugin (only if NHC is in PACKAGES)
  if [[ "$ENABLE_NHC_PLUGIN" == "true" ]] && [[ " ${PACKAGES[*]} " == *" ${NHC_PKG} "* ]]; then
    echo ""
    echo -e "${YELLOW}Enabling NHC console plugin: $NHC_CONSOLE_PLUGIN_NAME${NC}"
    if ! oc get consoleplugin "$NHC_CONSOLE_PLUGIN_NAME" &>/dev/null 2>&1; then
      echo "  ConsolePlugin $NHC_CONSOLE_PLUGIN_NAME not found yet (NHC operator may still be deploying it)."
    fi
    # spec.plugins lives on operator.openshift.io/v1 Console, not config.openshift.io
    if oc get console.operator.openshift.io cluster -o name &>/dev/null 2>&1; then
      current=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
      if echo "$current" | tr ' ' '\n' | grep -q "^${NHC_CONSOLE_PLUGIN_NAME}$"; then
        echo "  Plugin $NHC_CONSOLE_PLUGIN_NAME already enabled in Console."
      else
        if oc patch console.operator.openshift.io cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${NHC_CONSOLE_PLUGIN_NAME}\"}]" 2>/dev/null; then
          echo "  Enabled $NHC_CONSOLE_PLUGIN_NAME in Console."
        else
          oc patch console.operator.openshift.io cluster --type=merge -p "{\"spec\":{\"plugins\":[\"${NHC_CONSOLE_PLUGIN_NAME}\"]}}" 2>/dev/null && echo "  Enabled $NHC_CONSOLE_PLUGIN_NAME in Console." || echo "  Could not patch Console (plugin may need to be enabled manually)."
        fi
      fi
    else
      echo "  Console.operator.openshift.io cluster not found; skip plugin enable."
    fi
  fi

  # Remove duplicate subscriptions for the same package. OLM can create the long-named one
  # (e.g. self-node-remediation-stable-redhat-operators-openshift-marketplace). Run twice
  # and use a temp file so we don't miss any (no subshell from pipe).
  echo -e "\n${YELLOW}Removing duplicate subscriptions (keep only <package>-operator)...${NC}"
  _subs_tmp=$(mktemp)
  for _pass in 1 2; do
    [[ $_pass -eq 2 ]] && sleep 3
    oc get subscription -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.name}{"\n"}{end}' 2>/dev/null > "$_subs_tmp" || true
    while read -r sub_meta_name spec_name; do
      [[ -z "$sub_meta_name" ]] && continue
      # Is this one of our packages?
      found=""
      for pkg in "${ALL_PACKAGES[@]}"; do
        if [[ "$spec_name" == "$pkg" ]]; then
          canonical="${pkg}-operator"
          if [[ "$sub_meta_name" != "$canonical" ]]; then
            oc delete subscription "$sub_meta_name" -n "$NS" --ignore-not-found --timeout=30s 2>/dev/null && echo "  Deleted duplicate subscription: $sub_meta_name" || true
          fi
          break
        fi
      done
    done < "$_subs_tmp" 2>/dev/null || true
  done

  # Optionally enable NHC console plugin (only if NHC is in PACKAGES)
  if [[ "$ENABLE_NHC_PLUGIN" == "true" ]] && [[ " ${PACKAGES[*]} " == *" ${NHC_PKG} "* ]]; then
    echo ""
    echo -e "${YELLOW}Enabling NHC console plugin: $NHC_CONSOLE_PLUGIN_NAME${NC}"
    if ! oc get consoleplugin "$NHC_CONSOLE_PLUGIN_NAME" &>/dev/null; then
      echo "  Waiting for ConsolePlugin $NHC_CONSOLE_PLUGIN_NAME (up to ${NHC_CONSOLE_PLUGIN_WAIT}s)..."
      _cp_deadline=$(( $(date +%s) + NHC_CONSOLE_PLUGIN_WAIT ))
      while (( $(date +%s) < _cp_deadline )); do
        oc get consoleplugin "$NHC_CONSOLE_PLUGIN_NAME" &>/dev/null && break
        sleep 5
      done
    fi
    if ! oc get consoleplugin "$NHC_CONSOLE_PLUGIN_NAME" &>/dev/null; then
      echo -e "  ${RED}ConsolePlugin $NHC_CONSOLE_PLUGIN_NAME not found after ${NHC_CONSOLE_PLUGIN_WAIT}s — skipping plugin enable.${NC}" >&2
    elif oc get console.operator.openshift.io cluster -o name &>/dev/null; then
      current_json=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
      if echo "$current_json" | jq -e --arg p "$NHC_CONSOLE_PLUGIN_NAME" 'index($p) != null' &>/dev/null; then
        echo "  Plugin $NHC_CONSOLE_PLUGIN_NAME already enabled in Console."
      else
        new_plugins=$(echo "$current_json" | jq --arg p "$NHC_CONSOLE_PLUGIN_NAME" \
          'if type == "array" then . + [$p] | unique else [$p] end')
        patch_json=$(jq -n --argjson plugins "$new_plugins" '{"spec":{"plugins":$plugins}}')
        if oc patch console.operator.openshift.io cluster --type=merge -p "$patch_json" 2>/dev/null; then
          echo "  Enabled $NHC_CONSOLE_PLUGIN_NAME in Console."
        else
          echo "  Could not patch Console (plugin may need to be enabled manually)."
        fi
      fi
    else
      echo "  Console.operator.openshift.io cluster not found; skip plugin enable."
    fi
  fi

  echo ""
  echo -e "${GREEN}Done. Operators installed in namespace: $NS${NC}"
  echo "  Check: oc get csv -n $NS"
  echo "  Check: oc get pods -n $NS"
fi
