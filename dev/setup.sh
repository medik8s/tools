#!/bin/bash
# Medik8s development environment setup
# Creates a Kind cluster with 1 CP + 3 worker nodes, installs OLM,
# and prepares the namespace for operator deployment.
#
# Usage: ./setup.sh [--skip-olm] [--name <cluster-name>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
DEV_NS="${MEDIK8S_NAMESPACE:-medik8s-system}"
INSTALL_OLM=true
SKIP_KIND=false
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-kind)
            SKIP_KIND=true
            shift
            ;;
        --skip-olm)
            INSTALL_OLM=false
            shift
            ;;
        --name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--skip-kind] [--skip-olm] [--name <cluster-name>]"
            echo ""
            echo "Options:"
            echo "  --skip-kind   Skip Kind cluster creation (use existing cluster)"
            echo "  --skip-olm    Skip OLM installation"
            echo "  --name        Kind cluster name (default: medik8s-dev)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: $1 is required but not installed."
        echo "Install it from: $2"
        exit 1
    fi
}

echo "Using kubectl command: ${KUBECTL}"
echo "Using container tool: ${CONTAINER_TOOL}"

if [ "${SKIP_KIND}" = true ]; then
    echo "Using existing cluster (--skip-kind)."
    # Verify cluster connectivity
    if ! ${KUBECTL} cluster-info >/dev/null 2>&1; then
        echo "Error: cannot connect to cluster. Check your kubeconfig."
        exit 1
    fi
else
    check_tool kind "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    check_tool go "https://go.dev/doc/install"
    export KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}"

    # Check inotify limits — Kind nodes inherit host limits and operators need many watchers.
    INOTIFY_INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
    INOTIFY_WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
    if [ "${INOTIFY_INSTANCES}" -lt 512 ] || [ "${INOTIFY_WATCHES}" -lt 524288 ]; then
        echo ""
        echo "Warning: inotify limits are too low for running multiple operators in Kind."
        echo "  Current:     max_user_instances=${INOTIFY_INSTANCES}, max_user_watches=${INOTIFY_WATCHES}"
        echo "  Recommended: max_user_instances=8192, max_user_watches=524288"
        echo ""
        echo "Fix (requires sudo):"
        echo "  sudo sysctl -w fs.inotify.max_user_instances=8192"
        echo "  sudo sysctl -w fs.inotify.max_user_watches=524288"
        echo ""
        echo "To make persistent, add to /etc/sysctl.d/99-kind.conf:"
        echo "  fs.inotify.max_user_instances=8192"
        echo "  fs.inotify.max_user_watches=524288"
        echo ""
        # Try to fix automatically if running as root
        if [ "$(id -u)" = "0" ]; then
            echo "Running as root — fixing automatically."
            sysctl -w fs.inotify.max_user_instances=8192 >/dev/null
            sysctl -w fs.inotify.max_user_watches=524288 >/dev/null
        else
            echo "Error: inotify limits are too low and must be fixed before continuing."
            echo "Without sufficient inotify limits, Kind nodes may fail to join and operators will crash."
            exit 1
        fi
    fi

    # Check if cluster already exists.
    # Try 'kind get clusters' first, but also check kubectl connectivity —
    # the cluster may have been created with sudo (rootful podman) and won't
    # appear in rootless 'kind get clusters'.
    CLUSTER_EXISTS=false
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        CLUSTER_EXISTS=true
    elif ${KUBECTL} cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null; then
        CLUSTER_EXISTS=true
        echo "Note: cluster '${CLUSTER_NAME}' found via kubectl (created outside current user's Kind)."
    fi

    if [ "${CLUSTER_EXISTS}" = false ]; then
        # When using rootless podman, verify cgroup delegation includes cpuset.
        # Without cpuset, kubelet inside Kind worker nodes cannot start.
        if [ "${CONTAINER_TOOL}" = "podman" ] && [ "$(id -u)" != "0" ]; then
            CGROUP_SUBTREE="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control"
            if [ -f "${CGROUP_SUBTREE}" ]; then
                if ! grep -q 'cpuset' "${CGROUP_SUBTREE}" 2>/dev/null; then
                    echo ""
                    echo "Error: rootless podman detected but 'cpuset' cgroup controller is not delegated."
                    echo "Kind worker nodes will fail to start without it."
                    echo ""
                    echo "Fix: create a systemd override to delegate the required controllers:"
                    echo ""
                    echo "  sudo mkdir -p /etc/systemd/system/user@.service.d"
                    echo "  sudo tee /etc/systemd/system/user@.service.d/delegate.conf <<EOF"
                    echo "  [Service]"
                    echo "  Delegate=cpu cpuset io memory pids"
                    echo "  EOF"
                    echo "  sudo systemctl daemon-reload"
                    echo ""
                    echo "IMPORTANT: You must log out and log back in for the changes to take effect."
                    echo "A simple 'systemctl --user restart' is NOT sufficient — the user@.service"
                    echo "unit must be fully restarted, which only happens at login."
                    echo ""
                    echo "Alternatively, create the cluster with sudo:"
                    echo "  sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster \\"
                    echo "    --config ${KIND_CONFIG} --name ${CLUSTER_NAME}"
                    echo "  sudo kind get kubeconfig --name ${CLUSTER_NAME} > ~/.kube/config"
                    echo "Then re-run this command — it will detect the existing cluster and configure it."
                    exit 1
                fi
            fi
        fi

        echo "=== Creating Kind cluster '${CLUSTER_NAME}' ==="
        kind create cluster --config "${KIND_CONFIG}" --name "${CLUSTER_NAME}"
    else
        echo "=== Cluster '${CLUSTER_NAME}' already exists — skipping creation, re-applying configuration ==="
    fi

    echo "=== Waiting for all nodes to be Ready ==="
    ${KUBECTL} wait --for=condition=Ready node --all --timeout=120s

    echo "=== Labeling worker nodes ==="
    # Label any non-CP nodes with the worker role (idempotent)
    LABELED=0
    for node in $(${KUBECTL} get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
        if ! ${KUBECTL} get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'node-role.kubernetes.io/control-plane'; then
            if ${KUBECTL} get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'node-role.kubernetes.io/worker'; then
                continue
            fi
            ${KUBECTL} label node "$node" node-role.kubernetes.io/worker="" 2>/dev/null || true
            echo "  labeled $node"
            LABELED=$((LABELED + 1))
        fi
    done
    if [ "${LABELED}" -eq 0 ]; then
        echo "  All worker nodes already labeled."
    fi

    echo "=== Loading softdog kernel module on worker nodes (for SNR watchdog) ==="
    NODES=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null)
    if [ -z "${NODES}" ]; then
        NODES=$(${KUBECTL} get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
    fi
    for node in ${NODES}; do
        if echo "$node" | grep -q 'worker'; then
            ${CONTAINER_TOOL} exec "$node" modprobe softdog 2>/dev/null && \
                echo "  softdog loaded on $node" || \
                echo "  Warning: could not load softdog on $node (SNR watchdog reboot testing will be limited)"
        fi
    done
fi

echo "=== Ensuring namespace '${DEV_NS}' ==="
if ${KUBECTL} get namespace "${DEV_NS}" &>/dev/null; then
    echo "  Namespace '${DEV_NS}' already exists."
else
    ${KUBECTL} create namespace "${DEV_NS}"
fi
${KUBECTL} label --overwrite ns "${DEV_NS}" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged 2>&1 | grep -v 'not labeled' || true

# Also create the medik8s-leases namespace (used by common lease manager)
if ! ${KUBECTL} get namespace medik8s-leases &>/dev/null; then
    ${KUBECTL} create namespace medik8s-leases
else
    echo "  Namespace 'medik8s-leases' already exists."
fi

echo "=== Installing cert-manager ==="
if ${KUBECTL} get crd certificates.cert-manager.io &>/dev/null; then
    echo "  cert-manager already installed (CRDs found)."
else
    ${KUBECTL} apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
    echo "  Waiting for cert-manager to be ready..."
    ${KUBECTL} wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
fi

if [ "$INSTALL_OLM" = true ]; then
    if command -v operator-sdk &>/dev/null; then
        echo "=== Installing OLM ==="
        operator-sdk olm install 2>/dev/null || {
            echo "  OLM may already be installed or operator-sdk olm install failed."
            echo "  Continuing without OLM. Use 'make deploy' instead of 'make bundle-run'."
        }
    else
        echo "=== Skipping OLM (operator-sdk not found) ==="
        echo "  Install operator-sdk for OLM bundle testing, or use 'make deploy' for direct deployment."
    fi
fi

echo ""
echo "=== Medik8s dev environment ready ==="
echo ""
echo "  Cluster:   ${CLUSTER_NAME}"
echo "  Namespace: ${DEV_NS}"
echo "  Nodes:     $(${KUBECTL} get nodes --no-headers 2>/dev/null | wc -l) (1 CP + 3 workers)"
echo "  OLM:       $(${KUBECTL} get deployment -n olm olm-operator --no-headers >/dev/null 2>&1 && echo 'installed' || echo 'not installed')"
echo ""
echo "  Next steps:"
echo "    cd <operator-directory>"
echo "    make dev-deploy              # Build and deploy operator"
echo "    make dev-simulate-failure    # Trigger node failure"
echo "    make dev-logs                # Watch operator logs"
echo "    make dev-describe            # Check cluster state"
echo ""
