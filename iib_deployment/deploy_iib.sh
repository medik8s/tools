#!/bin/bash
set -euo pipefail

# Deploy an IIB CatalogSource on an OpenShift cluster (e.g., Cluster Bot AWS).
# Run with -h for usage.

NAMESPACE="openshift-operators"
CATSRC_PREFIX="rhwa-iib"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_DEFAULT_PATH="${SCRIPT_DIR}/secrets/brew-pull-secret.yaml"
IDMS_RAW_URL="https://gitlab.cee.redhat.com/api/v4/projects/dragonfly%2Frhwa-fbc/repository/files/.tekton%2Fimages-mirror-set.yaml/raw?ref=main"
DRY_RUN=false
CLEANUP=false
APPLY_IDMS=true
CONVERT_SECRET=false
SECRET_PATH=""

usage() {
    cat <<'EOF'
Usage: deploy_iib.sh <IIB_NUMBER> [OPTIONS]

Deploy an IIB CatalogSource on an OpenShift cluster.

Arguments:
  IIB_NUMBER              The IIB number (e.g., 1102943)

Options:
  --no-idms               Skip applying IDMS (applied by default)
  --convert-secret        Convert pull secret from registry.redhat.io to brew.registry.redhat.io
  --cleanup               Remove the CatalogSource and secret for this IIB
  --dry-run               Print commands without executing them
  --secret <PATH>         Path to brew pull secret YAML (default: iib_deployment/secrets/brew-pull-secret.yaml)
  --namespace <NS>        Target namespace (default: openshift-operators)
  -h, --help              Show this help

Prerequisites:
  1. oc login to target cluster
  2. Brew pull secret YAML at iib_deployment/secrets/brew-pull-secret.yaml
     Get from: https://access.redhat.com/terms-based-registry/
     Create a service account, download the OpenShift secret YAML,
     then modify the registry URL from registry.redhat.io to brew.registry.redhat.io
  3. GITLAB_PRIVATE_TOKEN env var (for fetching IDMS from private rhwa-fbc repo, skip with --no-idms)

Note: This script uses the OLM v0 CatalogSource API:
  https://olm.operatorframework.io/docs/concepts/crds/catalogsource/
  This will be replaced by ClusterCatalog in OLM v1:
  https://operator-framework.github.io/operator-controller/tutorials/add-catalog/
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
        echo "Error: Pull secret not found at ${SECRET_PATH}"
        echo ""
        echo "To create one:"
        echo "  1. Go to https://access.redhat.com/terms-based-registry/"
        echo "  2. Create a service account or use an existing one"
        echo "  3. Download the OpenShift secret YAML"
        echo "  4. Change the registry URL from registry.redhat.io to brew.registry.redhat.io"
        echo "  5. Save to ${SECRET_DEFAULT_PATH}"
        echo ""
        echo "Or pass --secret /path/to/secret.yaml"
        exit 1
    fi

    if [[ "${APPLY_IDMS}" == "true" && -z "${GITLAB_PRIVATE_TOKEN:-}" ]]; then
        echo "Error: GITLAB_PRIVATE_TOKEN env var is required to fetch IDMS from GitLab"
        echo "Export it before running:"
        echo "  export GITLAB_PRIVATE_TOKEN=<your-gitlab-cee-personal-access-token>"
        echo "  # Get from: https://gitlab.cee.redhat.com/-/user_settings/personal_access_tokens"
        echo ""
        echo "Or skip IDMS with --no-idms"
        exit 1
    fi
}

cleanup() {
    echo "Cleaning up IIB ${IIB_NR}..."

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

    echo "Cleanup complete"
    echo "Note: IDMS (imagedigestmirrorset) is not removed — delete manually if needed:"
    echo "  oc delete imagedigestmirrorset rhwa-fbc-fips-image-mirror-set"
}

convert_secret_to_brew() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required to convert the pull secret"
        exit 1
    fi

    local dockercfg_b64
    dockercfg_b64=$(grep '\.dockerconfigjson:' "${SECRET_PATH}" | awk '{print $2}')

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

create_catalogsource() {
    local image="brew.registry.redhat.io/rh-osbs/iib:${IIB_NR}"

    # OLM v0 CatalogSource API — will be replaced by ClusterCatalog in OLM v1
    # https://olm.operatorframework.io/docs/concepts/crds/catalogsource/
    # https://operator-framework.github.io/operator-controller/tutorials/add-catalog/
    echo "Creating CatalogSource '${CATSRC_NAME}' with image ${image}..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[dry-run] oc apply -f - (CatalogSource ${CATSRC_NAME}, image: ${image})"
    else
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATSRC_NAME}
  namespace: ${NAMESPACE}
spec:
  displayName: RHWA IIB ${IIB_NR}
  sourceType: grpc
  image: ${image}
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
        cleanup
        exit 0
    fi

    echo "=== Deploying IIB ${IIB_NR} ==="
    if [[ "${DRY_RUN}" == "false" ]]; then
        echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    fi
    echo "Namespace: ${NAMESPACE}"
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

    echo ""
    echo "=== IIB ${IIB_NR} deployed successfully ==="
    echo ""
    echo "Verify with:"
    echo "  oc get catalogsource ${CATSRC_NAME} -n ${NAMESPACE}"
    echo "  oc get pods -l olm.catalogSource=${CATSRC_NAME} -n ${NAMESPACE}"
    echo "  oc get packagemanifests -n ${NAMESPACE} | grep -E 'self-node-remediation|fence-agents-remediation|node-healthcheck-operator|node-maintenance-operator|machine-deletion-remediation|storage-based-remediation'"
    if [[ "${APPLY_IDMS}" == "false" ]]; then
        echo ""
        echo "IDMS was skipped. If operator images fail to pull, re-run without --no-idms"
    fi
}

# --- Argument parsing ---
[[ $# -eq 0 ]] && usage

IIB_NR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-idms)         APPLY_IDMS=false; shift ;;
        --convert-secret)  CONVERT_SECRET=true; shift ;;
        --cleanup)         CLEANUP=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --secret)          SECRET_PATH="$2"; shift 2 ;;
        --namespace)       NAMESPACE="$2"; shift 2 ;;
        -h|--help)         usage ;;
        -*)                echo "Unknown option: $1"; usage ;;
        *)
            if [[ -z "${IIB_NR}" ]]; then
                IIB_NR="$1"; shift
            else
                echo "Unexpected argument: $1"; usage
            fi
            ;;
    esac
done

[[ -z "${IIB_NR}" ]] && { echo "Error: IIB_NUMBER is required"; usage; }

CATSRC_NAME="${CATSRC_PREFIX}-${IIB_NR}"
SECRET_PATH="${SECRET_PATH:-${SECRET_DEFAULT_PATH}}"

main
