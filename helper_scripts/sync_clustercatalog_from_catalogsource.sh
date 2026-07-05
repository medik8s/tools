#!/usr/bin/env bash
################################################################################
# Align OLMv1 ClusterCatalog with a classic OLM CatalogSource (same catalog image ref).
#
# Also merges CatalogSource pull secrets into the cluster global pull-secret so
# catalogd can pull private index images (e.g. brew.registry.redhat.io). Without
# this, CatalogSource may be READY while ClusterCatalog stays unauthorized.
#
# If the ClusterCatalog does not exist, it is created (e.g. custom brew catalog name).
#
# Usage:
#   ./helper_scripts/sync_clustercatalog_from_catalogsource.sh
#   ./helper_scripts/sync_clustercatalog_from_catalogsource.sh \
#     --CATSRC_NAME=rhwa-release-catalog-brew \
#     --CLUSTERCATALOG_NAME=rhwa-release-cluster-catalog-brew
#   CATSRC_NAME=redhat-operators CLUSTERCATALOG_NAME=openshift-redhat-operators \
#     ./helper_scripts/sync_clustercatalog_from_catalogsource.sh
#
# Options (also available as env vars):
#   --CATSRC_NAME              CatalogSource name (default: redhat-operators)
#   --CATSRC_NS                CatalogSource namespace (default: openshift-marketplace)
#   --CLUSTERCATALOG_NAME      ClusterCatalog name (default: openshift-redhat-operators)
#   --CLUSTERCATALOG_LABEL     olm.operatorframework.io/metadata.name label on create
#                              (default: CLUSTERCATALOG_NAME)
#   --CLUSTERCATALOG_PRIORITY  priority on create (default: -100; lower than official catalogs)
#   --CATSRC_WAIT_TIMEOUT      Seconds to wait for CatalogSource READY (default: 600)
#   --CATALOG_WAIT_TIMEOUT     Seconds to wait for ClusterCatalog Serving (default: 600)
#   --SYNC_PULL_SECRETS        Merge CatalogSource spec.secrets into global pull-secret (default)
#   --SKIP_PULL_SECRET_SYNC    Skip global pull-secret merge
#   --WAIT                     Wait for CatalogSource READY and ClusterCatalog Serving (default)
#   --NO_WAIT                  Skip waits after patch/create
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rhwa_utils.sh
source "${SCRIPT_DIR}/lib/rhwa_utils.sh"

usage() {
  sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

CATSRC_NAME="${CATSRC_NAME:-redhat-operators}"
CATSRC_NS="${CATSRC_NS:-openshift-marketplace}"
CLUSTERCATALOG_NAME="${CLUSTERCATALOG_NAME:-openshift-redhat-operators}"
CLUSTERCATALOG_LABEL="${CLUSTERCATALOG_LABEL:-}"
CLUSTERCATALOG_PRIORITY="${CLUSTERCATALOG_PRIORITY:--100}"
SYNC_PULL_SECRETS=true
WAIT=true
CATSRC_WAIT_TIMEOUT="${CATSRC_WAIT_TIMEOUT:-600}"
CATALOG_WAIT_TIMEOUT="${CATALOG_WAIT_TIMEOUT:-600}"

set_var_from_arg() {
  local name="$1" value="$2"
  case "$name" in
    CATSRC_NAME) CATSRC_NAME="$value" ;;
    CATSRC_NS) CATSRC_NS="$value" ;;
    CLUSTERCATALOG_NAME) CLUSTERCATALOG_NAME="$value" ;;
    CLUSTERCATALOG_LABEL) CLUSTERCATALOG_LABEL="$value" ;;
    CLUSTERCATALOG_PRIORITY)
      [[ "$value" =~ ^-?[0-9]+$ ]] || { echo "Error: $name must be an integer" >&2; exit 1; }
      CLUSTERCATALOG_PRIORITY="$value"
      ;;
    CATSRC_WAIT_TIMEOUT)
      [[ "$value" =~ ^[0-9]+$ ]] || { echo "Error: $name must be a positive integer" >&2; exit 1; }
      CATSRC_WAIT_TIMEOUT="$value"
      ;;
    CATALOG_WAIT_TIMEOUT)
      [[ "$value" =~ ^[0-9]+$ ]] || { echo "Error: $name must be a positive integer" >&2; exit 1; }
      CATALOG_WAIT_TIMEOUT="$value"
      ;;
    *) echo "Error: unknown option --$name" >&2; exit 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --SYNC_PULL_SECRETS) SYNC_PULL_SECRETS=true; shift ;;
    --SKIP_PULL_SECRET_SYNC) SYNC_PULL_SECRETS=false; shift ;;
    --WAIT) WAIT=true; shift ;;
    --NO_WAIT) WAIT=false; shift ;;
    --*=*)
      opt="${1#--}"
      name="${opt%%=*}"
      value="${opt#*=}"
      set_var_from_arg "$name" "$value"
      shift
      ;;
    --CATSRC_NAME|--CATSRC_NS|--CLUSTERCATALOG_NAME|--CLUSTERCATALOG_LABEL|--CLUSTERCATALOG_PRIORITY|--CATSRC_WAIT_TIMEOUT|--CATALOG_WAIT_TIMEOUT)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      set_var_from_arg "${1#--}" "$2"
      shift 2
      ;;
    CATSRC_NAME=*|CATSRC_NS=*|CLUSTERCATALOG_NAME=*|CLUSTERCATALOG_LABEL=*|CLUSTERCATALOG_PRIORITY=*|CATSRC_WAIT_TIMEOUT=*|CATALOG_WAIT_TIMEOUT=*)
      set_var_from_arg "${1%%=*}" "${1#*=}"
      shift
      ;;
    *)
      echo "Error: unknown argument: $1 (use --help)" >&2
      exit 1
      ;;
  esac
done

[[ -z "$CLUSTERCATALOG_LABEL" ]] && CLUSTERCATALOG_LABEL="$CLUSTERCATALOG_NAME"

if ! oc whoami &>/dev/null; then
  echo "Error: not logged in. Run: oc login ..." >&2
  exit 1
fi

command -v jq >/dev/null || {
  echo "Error: jq required (patch/create ClusterCatalog)" >&2
  exit 1
}

if ! oc get catalogsource "$CATSRC_NAME" -n "$CATSRC_NS" &>/dev/null; then
  echo "Error: CatalogSource $CATSRC_NAME not found in $CATSRC_NS" >&2
  exit 1
fi

if [[ "$WAIT" == "true" ]]; then
  rhwa_wait_catsrc_ready "$CATSRC_NAME" "$CATSRC_NS" "$CATSRC_WAIT_TIMEOUT"
fi

if [[ "$SYNC_PULL_SECRETS" == "true" ]]; then
  echo "Syncing CatalogSource pull secrets into global pull-secret..."
  rhwa_merge_catsrc_pull_secrets_into_global "$CATSRC_NAME" "$CATSRC_NS"
fi

IMAGE_REF=$(oc get catalogsource "$CATSRC_NAME" -n "$CATSRC_NS" -o jsonpath='{.spec.image}')
if [[ -z "$IMAGE_REF" ]]; then
  echo "Error: CatalogSource $CATSRC_NAME has empty spec.image" >&2
  exit 1
fi

echo "CatalogSource $CATSRC_NAME image: $IMAGE_REF"

if oc get clustercatalog "$CLUSTERCATALOG_NAME" &>/dev/null; then
  echo "Patching ClusterCatalog $CLUSTERCATALOG_NAME to use the same ref..."
  patch_json=$(jq -n --arg ref "$IMAGE_REF" \
    '{"spec":{"source":{"type":"Image","image":{"ref":$ref}}}}')
  oc patch clustercatalog "$CLUSTERCATALOG_NAME" --type=merge -p "$patch_json"
else
  echo "ClusterCatalog $CLUSTERCATALOG_NAME not found; creating it..."
  if [[ "$IMAGE_REF" == *"@sha256:"* ]]; then
    create_json=$(jq -n \
      --arg name "$CLUSTERCATALOG_NAME" \
      --arg label "$CLUSTERCATALOG_LABEL" \
      --argjson priority "$CLUSTERCATALOG_PRIORITY" \
      --arg ref "$IMAGE_REF" \
      '{
        apiVersion: "olm.operatorframework.io/v1",
        kind: "ClusterCatalog",
        metadata: {
          name: $name,
          labels: {"olm.operatorframework.io/metadata.name": $label}
        },
        spec: {
          availabilityMode: "Available",
          priority: $priority,
          source: {type: "Image", image: {ref: $ref}}
        }
      }')
  else
    create_json=$(jq -n \
      --arg name "$CLUSTERCATALOG_NAME" \
      --arg label "$CLUSTERCATALOG_LABEL" \
      --argjson priority "$CLUSTERCATALOG_PRIORITY" \
      --arg ref "$IMAGE_REF" \
      '{
        apiVersion: "olm.operatorframework.io/v1",
        kind: "ClusterCatalog",
        metadata: {
          name: $name,
          labels: {"olm.operatorframework.io/metadata.name": $label}
        },
        spec: {
          availabilityMode: "Available",
          priority: $priority,
          source: {
            type: "Image",
            image: {ref: $ref, pollIntervalMinutes: 10}
          }
        }
      }')
  fi
  echo "$create_json" | oc apply -f -
  echo "Created ClusterCatalog $CLUSTERCATALOG_NAME (label: ${CLUSTERCATALOG_LABEL})"
fi

if [[ "$WAIT" == "true" ]]; then
  rhwa_wait_clustercatalog_serving "$CLUSTERCATALOG_NAME" "$CATALOG_WAIT_TIMEOUT"
fi

echo "Done. Watch: oc get clustercatalog $CLUSTERCATALOG_NAME -w"
echo "  oc describe clustercatalog $CLUSTERCATALOG_NAME"
