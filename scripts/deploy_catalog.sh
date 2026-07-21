#!/bin/bash
set -euo pipefail

# Deploy an operator catalog on an OpenShift cluster (e.g., Cluster Bot AWS).
# Supports IIB index images (by number) and FBC fragment images (by digest).
# Supports OLM v0 (CatalogSource) and OLM v1 (ClusterCatalog).
# Run with -h for usage.

NAMESPACE="openshift-operators"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_DEFAULT_PATH="${SCRIPT_DIR}/secrets/brew-pull-secret.yaml"
IDMS_RAW_URL="https://gitlab.cee.redhat.com/api/v4/projects/dragonfly%2Frhwa-fbc/repository/files/.tekton%2Fimages-mirror-set.yaml/raw?ref=main"
DRY_RUN=false
CLEANUP=false
APPLY_IDMS=true
CONVERT_SECRET=false
SECRET_PATH=""
OLM_VERSION="v0"
FBC_BASE=""
OCP_VER="422"
CATSRC_NAME_OVERRIDE=""

# shellcheck source=lib/rhwa_utils.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rhwa_utils.sh"

usage() {
    cat <<'EOF'
Usage: deploy_catalog.sh <IIB_NUMBER | sha256:DIGEST> [OPTIONS]

Deploy an operator catalog on an OpenShift cluster.
Supports IIB index images (by number) and FBC fragment images (by digest).

Arguments:
  IIB_NUMBER              IIB build number (e.g., 1181614)
  sha256:DIGEST           FBC image digest (e.g., sha256:abc123...)

Options:
  --olm v0|v1             OLM version: v0 creates CatalogSource (default),
                           v1 creates ClusterCatalog directly
  --no-idms               Skip applying IDMS (applied by default)
  --convert-secret        Convert pull secret from registry.redhat.io to brew.registry.redhat.io
  --cleanup               Remove the catalog and secret for this catalog
  --dry-run               Print commands without executing them
  --secret <PATH>         Path to brew pull secret YAML (default: scripts/secrets/brew-pull-secret.yaml)
  --namespace <NS>        Target namespace for v0 CatalogSource (default: openshift-operators)
  --name <NAME>           Override the auto-derived catalog name
  -h, --help              Show this help

FBC options (only used with sha256:DIGEST):
  --fbc-base <IMAGE>      Base FBC image path
                           (default: quay.io/redhat-user-workloads/rhwa-tenant/rhwa-fbc/rhwa-fbc-<ocp-ver>)
  --ocp-ver <VER>         OCP version suffix for --fbc-base default and catalog name (default: 422)

Prerequisites:
  1. oc login to target cluster
  2. Pull secret YAML at scripts/secrets/brew-pull-secret.yaml
     Get from: https://access.redhat.com/terms-based-registry/
     Create a service account and download the OpenShift secret YAML.
     If the secret targets registry.redhat.io, use --convert-secret to
     automatically convert it to brew.registry.redhat.io
  3. GITLAB_PRIVATE_TOKEN env var (for fetching IDMS from private rhwa-fbc repo, skip with --no-idms)

Examples:
  # Deploy from IIB (legacy):
  deploy_catalog.sh 1181614 --convert-secret

  # Deploy FBC fragment directly:
  deploy_catalog.sh sha256:abc123def456... --ocp-ver 422

  # Deploy FBC with custom base image:
  deploy_catalog.sh sha256:abc123... --fbc-base quay.io/my-org/my-fbc

  # Deploy FBC with custom catalog name:
  deploy_catalog.sh sha256:abc123... --name my-test-catalog

OLM v0 (default): creates CatalogSource + namespace pull secret + SA patch
OLM v1 (--olm v1): creates ClusterCatalog + merges pull secret into global pull-secret
  See: https://operator-framework.github.io/operator-controller/tutorials/add-catalog/
EOF
    exit 0
}

run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

get_secret_name() {
    grep -m1 '^\s*name:' "${SECRET_PATH}" | awk '{print $2}'
}

check_prerequisites() {
    if ! command -v oc &>/dev/null; then
        echo "Error: oc CLI not found"
        exit 1
    fi

    if [[ "${DRY_RUN}" == "false" ]] && ! oc whoami &>/dev/null; then
        echo "Error: not logged into an OpenShift cluster (run 'oc login' first)"
        exit 1
    fi

    if [[ "${CLEANUP}" == "false" && ! -f "${SECRET_PATH}" ]]; then
        cat <<ERRMSG
Error: Pull secret not found at ${SECRET_PATH}

To create one:
  1. Go to https://access.redhat.com/terms-based-registry/
  2. Create a service account or use an existing one
  3. Download the OpenShift secret YAML
  4. Use --convert-secret to convert it to brew.registry.redhat.io
  5. Save to ${SECRET_DEFAULT_PATH}

Or pass --secret /path/to/secret.yaml
ERRMSG
        exit 1
    fi

    if [[ "${APPLY_IDMS}" == "true" && -z "${GITLAB_PRIVATE_TOKEN:-}" ]]; then
        cat <<ERRMSG
Error: GITLAB_PRIVATE_TOKEN env var is required to fetch IDMS from GitLab
Export it before running:
  export GITLAB_PRIVATE_TOKEN=<your-gitlab-cee-personal-access-token>
  # Get from: https://gitlab.cee.redhat.com/-/user_settings/personal_access_tokens

Or skip IDMS with --no-idms
ERRMSG
        exit 1
    fi

    if [[ "${OLM_VERSION}" == "v1" ]]; then
        command -v jq >/dev/null || {
            echo "Error: jq required for OLM v1 ClusterCatalog creation"
            exit 1
        }
        if [[ "${DRY_RUN}" == "false" ]]; then
            if ! oc api-resources --api-group=olm.operatorframework.io 2>/dev/null | grep -q ClusterCatalog; then
                echo "Error: OLM v1 CRDs not found on this cluster (ClusterCatalog). OLM v1 requires OCP >= 4.18." >&2
                exit 1
            fi
        fi
    fi
}

# --- OLM v0 functions ---

cleanup_v0() {
    echo "Cleaning up catalog ${CATSRC_NAME} (OLM v0)..."

    if [[ "${DRY_RUN}" == "false" ]] && oc get catalogsource "${CATSRC_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        echo "Deleting CatalogSource '${CATSRC_NAME}'..."
        run_cmd oc delete catalogsource "${CATSRC_NAME}" -n "${NAMESPACE}"
    elif [[ "${DRY_RUN}" == "true" ]]; then
        echo "[dry-run] oc delete catalogsource ${CATSRC_NAME} -n ${NAMESPACE}"
    else
        echo "CatalogSource '${CATSRC_NAME}' not found, skipping"
    fi

    if [[ -f "${SECRET_PATH}" ]]; then
        local secret_name
        secret_name=$(get_secret_name)
        if [[ "${DRY_RUN}" == "false" ]] && oc get secret "${secret_name}" -n "${NAMESPACE}" &>/dev/null; then
            echo "Deleting secret '${secret_name}'..."
            run_cmd oc delete secret "${secret_name}" -n "${NAMESPACE}"
        elif [[ "${DRY_RUN}" == "true" ]]; then
            echo "[dry-run] oc delete secret ${secret_name} -n ${NAMESPACE}"
        fi
    fi

    cat <<MSG
Cleanup complete
Note: IDMS (imagedigestmirrorset) is not removed — delete manually if needed:
  oc delete imagedigestmirrorset rhwa-fbc-fips-image-mirror-set
MSG
}

create_catalogsource() {
    echo "Creating CatalogSource '${CATSRC_NAME}' with image ${IMAGE}..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[dry-run] oc apply -f - (CatalogSource ${CATSRC_NAME}, image: ${IMAGE})"
    else
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATSRC_NAME}
  namespace: ${NAMESPACE}
spec:
  displayName: ${DISPLAY_NAME}
  sourceType: grpc
  image: ${IMAGE}
EOF
    fi
}

create_pull_secret() {
    local secret_name
    secret_name=$(get_secret_name)
    echo "Applying pull secret '${secret_name}' in namespace ${NAMESPACE}..."

    if [[ "${DRY_RUN}" == "false" ]] && oc get secret "${secret_name}" -n "${NAMESPACE}" &>/dev/null; then
        echo "Secret '${secret_name}' already exists, skipping"
    else
        run_cmd oc create -f "${SECRET_PATH}" --namespace="${NAMESPACE}"
    fi
}

patch_service_account() {
    local secret_name
    secret_name=$(get_secret_name)
    echo "Patching ServiceAccount '${CATSRC_NAME}' with pull secret '${secret_name}'..."
    run_cmd oc patch sa "${CATSRC_NAME}" -n "${NAMESPACE}" \
        --type=json \
        -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"'"${secret_name}"'"}}]'

    if [[ "${DRY_RUN}" == "false" ]]; then
        echo "Waiting for pod to restart after SA patch..."
        sleep 5
        echo "Waiting for CatalogSource pod to be ready (timeout 120s)..."
        oc wait --for=condition=ready pod \
            -l "olm.catalogSource=${CATSRC_NAME}" \
            -n "${NAMESPACE}" \
            --timeout=120s
    fi
}

deploy_v0() {
    echo "=== Deploying catalog ${CATSRC_NAME} (OLM v0) ==="
    echo "  Mode: ${MODE}, Image: ${IMAGE}"
    if [[ "${DRY_RUN}" == "false" ]]; then
        echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    fi
    echo "  Namespace: ${NAMESPACE}"
    echo ""

    if [[ "${CONVERT_SECRET}" == "true" ]]; then
        convert_secret_to_brew
    fi

    create_catalogsource

    echo ""
    echo "Waiting for ServiceAccount '${CATSRC_NAME}' to be created by OLM..."
    if [[ "${DRY_RUN}" == "false" ]]; then
        for i in $(seq 1 30); do
            if oc get sa "${CATSRC_NAME}" -n "${NAMESPACE}" &>/dev/null; then
                break
            fi
            if [[ $i -eq 30 ]]; then
                echo "Error: ServiceAccount '${CATSRC_NAME}' not created after 30s"
                echo "Check: oc get catalogsource ${CATSRC_NAME} -n ${NAMESPACE} -o yaml"
                exit 1
            fi
            sleep 1
        done
    fi

    create_pull_secret
    echo ""
    patch_service_account

    if [[ "${APPLY_IDMS}" == "true" ]]; then
        echo ""
        apply_idms
    fi

    local idms_note=""
    if [[ "${APPLY_IDMS}" == "false" ]]; then
        idms_note=$'\nIDMS was skipped. If operator images fail to pull, re-run without --no-idms'
    fi

    cat <<MSG

=== Catalog ${CATSRC_NAME} deployed successfully (OLM v0) ===

Verify with:
  oc get catalogsource ${CATSRC_NAME} -n ${NAMESPACE}
  oc get packagemanifests -n ${NAMESPACE} | grep -E 'self-node-remediation|fence-agents-remediation|node-healthcheck-operator|node-maintenance-operator|machine-deletion-remediation|storage-based-remediation'${idms_note}
MSG
}

# --- OLM v1 functions ---

cleanup_v1() {
    echo "Cleaning up catalog ${CATSRC_NAME} (OLM v1)..."

    if [[ "${DRY_RUN}" == "false" ]] && oc get clustercatalog "${CATSRC_NAME}" &>/dev/null; then
        echo "Deleting ClusterCatalog '${CATSRC_NAME}'..."
        run_cmd oc delete clustercatalog "${CATSRC_NAME}" --timeout=60s
    elif [[ "${DRY_RUN}" == "true" ]]; then
        echo "[dry-run] oc delete clustercatalog ${CATSRC_NAME}"
    else
        echo "ClusterCatalog '${CATSRC_NAME}' not found, skipping"
    fi

    cat <<MSG
Cleanup complete
Note: IDMS (imagedigestmirrorset) is not removed — delete manually if needed:
  oc delete imagedigestmirrorset rhwa-fbc-fips-image-mirror-set
Note: Global pull-secret entries added during deploy are not removed.
MSG
}

create_clustercatalog() {
    echo "Creating ClusterCatalog '${CATSRC_NAME}' with image ${IMAGE}..."

    local manifest
    manifest=$(jq -n \
        --arg name "$CATSRC_NAME" \
        --arg ref "$IMAGE" \
        '{
            apiVersion: "olm.operatorframework.io/v1",
            kind: "ClusterCatalog",
            metadata: {
                name: $name,
                labels: {"olm.operatorframework.io/metadata.name": $name}
            },
            spec: {
                availabilityMode: "Available",
                priority: -100,
                source: {type: "Image", image: {ref: $ref, pollIntervalMinutes: 10}}
            }
        }')
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "$manifest"
        echo "[dry-run] oc apply -f - (ClusterCatalog ${CATSRC_NAME})"
    else
        echo "$manifest" | oc apply -f -
    fi
}

merge_pull_secret_to_global() {
    echo "Merging brew pull secret into global pull-secret for catalogd..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[dry-run] merge ${SECRET_PATH} -> openshift-config/pull-secret"
        return
    fi

    local tmpdir dockercfg_b64
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir:-}"' RETURN

    dockercfg_b64=$(grep -m1 '\.dockerconfigjson:' "${SECRET_PATH}" | awk '{print $2}')
    if [[ -z "${dockercfg_b64}" ]]; then
        echo "Error: .dockerconfigjson not found in ${SECRET_PATH}" >&2
        return 1
    fi
    echo "${dockercfg_b64}" | base64 --decode > "${tmpdir}/brew-secret.json"

    rhwa_merge_secret_file_into_global "${tmpdir}/brew-secret.json" "brew pull secret"
}

deploy_v1() {
    echo "=== Deploying catalog ${CATSRC_NAME} (OLM v1) ==="
    echo "  Mode: ${MODE}, Image: ${IMAGE}"
    if [[ "${DRY_RUN}" == "false" ]]; then
        echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    fi
    echo ""

    if [[ "${CONVERT_SECRET}" == "true" ]]; then
        convert_secret_to_brew
    fi

    merge_pull_secret_to_global

    echo ""
    create_clustercatalog

    if [[ "${DRY_RUN}" == "false" ]]; then
        echo ""
        rhwa_wait_clustercatalog_serving "${CATSRC_NAME}" 600
    fi

    if [[ "${APPLY_IDMS}" == "true" ]]; then
        echo ""
        apply_idms
    fi

    local idms_note=""
    if [[ "${APPLY_IDMS}" == "false" ]]; then
        idms_note=$'\nIDMS was skipped. If operator images fail to pull, re-run without --no-idms'
    fi

    cat <<MSG

=== Catalog ${CATSRC_NAME} deployed successfully (OLM v1) ===

Verify with:
  oc get clustercatalog ${CATSRC_NAME}
  oc describe clustercatalog ${CATSRC_NAME}${idms_note}

Next: install operators with:
  ./scripts/install_rhwa_operators.sh --olm v1 --catsrc ${CATSRC_NAME}
MSG
}

# --- Shared functions ---

convert_secret_to_brew() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required to convert the pull secret"
        exit 1
    fi

    local dockercfg_b64
    dockercfg_b64=$(grep -m1 '\.dockerconfigjson:' "${SECRET_PATH}" | awk '{print $2}')

    if echo "${dockercfg_b64}" | base64 --decode 2>/dev/null | jq -e '.auths["brew.registry.redhat.io"]' &>/dev/null; then
        echo "Secret already targets brew.registry.redhat.io, no conversion needed"
        return
    fi

    echo "Converting pull secret from registry.redhat.io to brew.registry.redhat.io..."

    local modified_cfg
    modified_cfg=$(echo "${dockercfg_b64}" | base64 --decode | jq \
        '.auths |= (if .["registry.redhat.io"] then (.["brew.registry.redhat.io"] = .["registry.redhat.io"]) | del(.["registry.redhat.io"]) else . end)')

    local new_b64
    new_b64=$(echo -n "${modified_cfg}" | base64 -w 0)

    sed -i "s|\.dockerconfigjson:.*|.dockerconfigjson: ${new_b64}|" "${SECRET_PATH}"

    local secret_name
    secret_name=$(get_secret_name)
    local new_name="brew-${secret_name}"
    sed -i "s|name: ${secret_name}|name: ${new_name}|" "${SECRET_PATH}"

    echo "Converted: registry.redhat.io -> brew.registry.redhat.io"
    echo "Renamed secret: ${secret_name} -> ${new_name}"
}

apply_idms() {
    echo "Fetching IDMS from rhwa-fbc repo..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[dry-run] curl + oc apply -f - (IDMS from rhwa-fbc/.tekton/images-mirror-set.yaml)"
    else
        local idms_content
        idms_content=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_PRIVATE_TOKEN}" "${IDMS_RAW_URL}")
        if [[ -z "${idms_content}" ]]; then
            echo "Error: Failed to fetch IDMS from GitLab"
            exit 1
        fi
        echo "${idms_content}" | oc apply -f -
    fi

    echo ""
    echo "Note: If this is the first time applying the IDMS, it triggers a MachineConfigPool update."
    echo "Nodes will be drained and rebooted. Monitor with: oc get mcp"
}

main() {
    check_prerequisites

    if [[ "${CLEANUP}" == "true" ]]; then
        if [[ "${OLM_VERSION}" == "v1" ]]; then
            cleanup_v1
        else
            cleanup_v0
        fi
        exit 0
    fi

    if [[ "${OLM_VERSION}" == "v1" ]]; then
        deploy_v1
    else
        deploy_v0
    fi
}

# --- Argument parsing ---
[[ $# -eq 0 ]] && usage

INPUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --olm)
            [[ $# -lt 2 ]] && { echo "Error: --olm requires a value (v0 or v1)" >&2; exit 1; }
            OLM_VERSION="$2"
            if [[ "$OLM_VERSION" != "v0" && "$OLM_VERSION" != "v1" ]]; then
                echo "Error: --olm must be v0 or v1 (got: ${OLM_VERSION})" >&2
                exit 1
            fi
            shift 2
            ;;
        --no-idms)         APPLY_IDMS=false; shift ;;
        --convert-secret)  CONVERT_SECRET=true; shift ;;
        --cleanup)         CLEANUP=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --secret)          [[ $# -lt 2 ]] && { echo "Error: --secret requires a path" >&2; exit 1; }; SECRET_PATH="$2"; shift 2 ;;
        --namespace)       [[ $# -lt 2 ]] && { echo "Error: --namespace requires a value" >&2; exit 1; }; NAMESPACE="$2"; shift 2 ;;
        --fbc-base)        [[ $# -lt 2 ]] && { echo "Error: --fbc-base requires an image path" >&2; exit 1; }; FBC_BASE="$2"; shift 2 ;;
        --ocp-ver)         [[ $# -lt 2 ]] && { echo "Error: --ocp-ver requires a version" >&2; exit 1; }; OCP_VER="$2"; shift 2 ;;
        --name)            [[ $# -lt 2 ]] && { echo "Error: --name requires a value" >&2; exit 1; }; CATSRC_NAME_OVERRIDE="$2"; shift 2 ;;
        -h|--help)         usage ;;
        -*)                echo "Unknown option: $1"; usage ;;
        *)
            if [[ -z "${INPUT}" ]]; then
                INPUT="$1"; shift
            else
                echo "Unexpected argument: $1"; usage
            fi
            ;;
    esac
done

[[ -z "${INPUT}" ]] && { echo "Error: IIB_NUMBER or sha256:DIGEST is required"; usage; }

# Detect mode and derive IMAGE, CATSRC_NAME, DISPLAY_NAME
if [[ "${INPUT}" =~ ^[0-9]+$ ]]; then
    MODE="iib"
    IMAGE="brew.registry.redhat.io/rh-osbs/iib:${INPUT}"
    CATSRC_NAME="${CATSRC_NAME_OVERRIDE:-rhwa-iib-${INPUT}}"
    DISPLAY_NAME="RHWA IIB ${INPUT}"
elif [[ "${INPUT}" =~ ^sha256: ]]; then
    MODE="fbc"
    FBC_BASE="${FBC_BASE:-quay.io/redhat-user-workloads/rhwa-tenant/rhwa-fbc/rhwa-fbc-${OCP_VER}}"
    IMAGE="${FBC_BASE}@${INPUT}"
    CATSRC_NAME="${CATSRC_NAME_OVERRIDE:-rhwa-fbc-${OCP_VER}}"
    DISPLAY_NAME="RHWA FBC ${OCP_VER}"
else
    echo "Error: argument must be an IIB number (numeric) or FBC digest (sha256:...)" >&2
    echo "  Got: ${INPUT}" >&2
    exit 1
fi

SECRET_PATH="${SECRET_PATH:-${SECRET_DEFAULT_PATH}}"

main
