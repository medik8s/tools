#!/bin/bash
# Medik8s development environment setup
# Creates a Kind cluster with 1 CP + 3 worker nodes (default), installs OLM,
# and prepares the namespace for operator deployment.
#
# Usage: ./setup.sh [--skip-olm] [--skip-registry] [--name <cluster-name>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
# Shared namespace for dev resources (PSA-privileged). Operators deploy into
# their own namespaces (from kustomization.yaml), not this one.
DEV_NS="${MEDIK8S_NAMESPACE:-medik8s-system}"
INSTALL_OLM=true
# Honor both the flag and the environment: CI sets these as variables.
SKIP_KIND="${SKIP_KIND:-false}"
USE_KIND="${USE_KIND:-false}"
SKIP_INOTIFY_CHECK=false
SKIP_REGISTRY="${SKIP_REGISTRY:-false}"
REG_NAME="${MEDIK8S_REGISTRY_NAME:-kind-registry}"
REG_PORT="${MEDIK8S_REGISTRY_PORT:-5000}"
KIND_HA="${KIND_HA:-false}"
KIND_BLOCK_STORAGE="${KIND_BLOCK_STORAGE:-false}"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-kind)
            SKIP_KIND=true
            shift
            ;;
        --use-kind)
            USE_KIND=true
            shift
            ;;
        --skip-olm)
            INSTALL_OLM=false
            shift
            ;;
        --skip-inotify-check)
            SKIP_INOTIFY_CHECK=true
            shift
            ;;
        --skip-registry)
            SKIP_REGISTRY=true
            shift
            ;;
        --ha)
            KIND_HA=true
            shift
            ;;
        --name)
            if [[ $# -lt 2 ]]; then
                echo "Error: --name requires a cluster name argument."
                exit 1
            fi
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--skip-kind|--use-kind] [--skip-olm] [--skip-inotify-check] [--ha] [--name <cluster-name>]"
            echo ""
            echo "Without either flag, the cluster you are logged into is used (after"
            echo "confirmation); Kind is created when nothing is reachable."
            echo ""
            echo "Options:"
            echo "  --skip-kind           Use the cluster you are logged into, no questions asked"
            echo "  --use-kind            Create/use the local Kind cluster even when logged in elsewhere"
            echo "  --skip-olm            Skip OLM installation"
            echo "  --skip-registry       Skip local registry creation"
            echo "  --skip-inotify-check  Skip inotify limits check"
            echo "  --ha                  Use HA config (3 CP + 3 workers, for SNR CP testing)"
            echo "  --name                Kind cluster name (default: medik8s-dev)"
            echo ""
            echo "Environment variables:"
            echo "  DEV_REGISTRY              Image delivery: 'registry' (local registry, default for Kind),"
            echo "                            'local' (kind load, no registry), 'ttl.sh' (ephemeral push)"
            echo "  MEDIK8S_REGISTRY_NAME     Local registry container name (default: kind-registry)"
            echo "  MEDIK8S_REGISTRY_PORT     Local registry port (default: 5000)"
            echo "  MEDIK8S_CLUSTER_NAME      Kind cluster name (default: medik8s-dev)"
            echo "  MEDIK8S_NAMESPACE         Shared dev namespace (default: medik8s-system)"
            echo "  CERT_MANAGER_VERSION           Cert-manager version (default: v1.17.2)
  SETUP_NULL_DEVICE_WATCHDOG     Set to 'true' to create a per-node null /dev/watchdog (SBR multi-node e2e)
  SETUP_NFS_RWX                  Set to 'true' to install csi-driver-nfs + NFS server StorageClass (SBR fs e2e)
  SETUP_DOCKER_SOCKET            Set to 'true' to bind-mount /var/run/docker.sock into the control-plane node (FAR fence_docker e2e)"
            echo "  SETUP_MDR_MOCK            Set to 'true' to install Machine API CRDs and worker fixtures"
            echo "  MDR_CRD_DIR               Directory containing the Machine/MachineSet CRD manifests"
            echo "  SKIP_KIND                 Set to 'true' to skip Kind cluster creation"
            echo "  SKIP_REGISTRY             Set to 'true' to skip local registry creation"
            echo "  KIND_HA                   Set to 'true' for HA config (3 CP + 3 workers)"
            echo "  KIND_BLOCK_STORAGE        Share a disposable raw block device across 2 workers (Linux/Docker or Podman)"
            echo "  KIND_BLOCK_STATE_DIR      Absolute directory for block state and isolated kubeconfig"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "${SETUP_MDR_MOCK:-false}" = true ]; then
    if [ "${SKIP_KIND}" = true ] || [ "${KIND_HA}" = true ]; then
        echo "SETUP_MDR_MOCK requires a Kind cluster with one control plane; --skip-kind and --ha are unsupported." >&2
        exit 1
    fi
    for resource in machines machinesets; do
        if [ -z "${MDR_CRD_DIR:-}" ] || [ ! -f "${MDR_CRD_DIR}/0000_10_machine-api_01_${resource}-Default.crd.yaml" ]; then
            echo "SETUP_MDR_MOCK requires MDR_CRD_DIR containing the Machine and MachineSet CRD manifests." >&2
            exit 1
        fi
    done
fi

if [ "${KIND_HA}" = true ]; then
    KIND_CONFIG="${SCRIPT_DIR}/kind-config-ha.yaml"
fi

if [ "${KIND_BLOCK_STORAGE}" = true ]; then
    if [ "${SKIP_KIND}" = true ]; then
        echo "KIND_BLOCK_STORAGE requires creating a Kind cluster; --skip-kind is unsupported." >&2
        exit 1
    fi
    source "${SCRIPT_DIR}/kind-block.sh"
    kind_block_state
    kind_block_check_host
fi

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

# Which cluster is this run about? The session you are logged into wins; Kind
# is for when you ask for it, or when there is nothing to log into. Decided
# before the host checks so they only run when a Kind cluster is involved.
#
#   --skip-kind / SKIP_KIND=true     use the current session (explicit)
#   --use-kind  / USE_KIND=true      create/use Kind even if logged in elsewhere
#   KIND_BLOCK_STORAGE/SETUP_MDR_MOCK  imply Kind: they build Kind nodes
#   context is kind-<cluster name>   the dev cluster is the session
#   any other reachable context      use it, after confirming
#   nothing reachable                create the Kind cluster
if [ "${USE_KIND}" = true ] && [ "${SKIP_KIND}" = true ]; then
    echo "Error: --use-kind and --skip-kind are mutually exclusive." >&2
    exit 1
fi

CURRENT_CONTEXT=$(${KUBECTL} config current-context 2>/dev/null || true)
if [ "${SKIP_KIND}" != true ] && [ "${USE_KIND}" != true ] && \
   [ -n "${CURRENT_CONTEXT}" ] && [ "${CURRENT_CONTEXT}" != "kind-${CLUSTER_NAME}" ]; then
    if [ "${KIND_BLOCK_STORAGE}" = true ] || [ "${SETUP_MDR_MOCK:-false}" = true ]; then
        echo "Note: KIND_BLOCK_STORAGE/SETUP_MDR_MOCK need Kind nodes — creating the Kind cluster"
        echo "  and switching your context away from '${CURRENT_CONTEXT}'."
    elif ! ${KUBECTL} cluster-info --request-timeout=10s >/dev/null 2>&1; then
        echo "Note: context '${CURRENT_CONTEXT}' is not reachable; creating the Kind cluster instead."
    elif [ "${CURRENT_CONTEXT#kind-}" != "${CURRENT_CONTEXT}" ]; then
        # Another local Kind cluster: disposable, no confirmation needed.
        echo "Using the cluster you are on: '${CURRENT_CONTEXT}'."
        SKIP_KIND=true
    else
        CURRENT_SERVER=$(${KUBECTL} config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
        echo ""
        echo "=== Target cluster ==="
        echo "  You are logged into '${CURRENT_CONTEXT}'${CURRENT_SERVER:+ (${CURRENT_SERVER})}."
        echo "  Setting up THERE means: creating the dev namespaces, and installing cert-manager"
        echo "  and OLM if they are missing. Nothing is created locally."
        echo "  For a local Kind cluster instead, re-run with USE_KIND=true."
        echo ""
        if [ -t 0 ]; then
            read -r -p "  Configure '${CURRENT_CONTEXT}'? [y/N] " REPLY
            case "${REPLY}" in
                [yY]|[yY][eE][sS]) SKIP_KIND=true ;;
                *) echo "  Aborted. Use USE_KIND=true for a local Kind cluster."; exit 1 ;;
            esac
        else
            echo "  Refusing to configure a remote cluster unconfirmed in a non-interactive shell." >&2
            echo "  Re-run with SKIP_KIND=true to confirm, or USE_KIND=true for a local Kind cluster." >&2
            exit 1
        fi
    fi
    echo ""
fi

# Check the host — permissions included — before creating anything, so a
# missing privilege is reported with its fix instead of failing mid-setup.
# shellcheck disable=SC2034  # read by preflight.sh, sourced below
PF_SKIP_INOTIFY="${SKIP_INOTIFY_CHECK}"
# setup.sh is allowed to change the host; 'make dev-preflight' is not.
# shellcheck disable=SC2034  # read by preflight.sh, sourced below
PF_AUTO_FIX_INOTIFY=true
# shellcheck source=preflight.sh
source "${SCRIPT_DIR}/preflight.sh"
preflight_run || exit 1
echo ""

if [ "${SKIP_KIND}" = true ]; then
    echo "Using the cluster from your kubeconfig context '${CURRENT_CONTEXT:-<none>}'."
    # Verify cluster connectivity
    if ! ${KUBECTL} cluster-info >/dev/null 2>&1; then
        echo "Error: cannot connect to cluster. Check your kubeconfig."
        exit 1
    fi
else
    check_tool kind "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    check_tool go "https://go.dev/doc/install"

    # Kind >= 0.22.0 defaults to K8s 1.29+, required for cert-manager CRD features (selectableFields).
    MIN_KIND_VERSION="0.22.0"
    KIND_VERSION=$(kind version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "${KIND_VERSION}" ] && printf '%s\n%s\n' "${MIN_KIND_VERSION}" "${KIND_VERSION}" | sort -V -C; then
        : # version is sufficient
    else
        echo "Error: Kind >= ${MIN_KIND_VERSION} is required (found: ${KIND_VERSION:-unknown})."
        echo "Install from: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
        exit 1
    fi

    export KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}"

    # Pre-cluster registry setup: configure host DNS and Docker daemon BEFORE
    # creating the Kind cluster (Docker restart would kill Kind containers).
    if [ "${SKIP_REGISTRY}" != true ]; then
        echo "=== Configuring host for local registry '${REG_NAME}:${REG_PORT}' ==="

        # Make the registry hostname resolvable from the host. The OLM targets
        # push and render ${REG_NAME}:${REG_PORT} from here, so fix it now —
        # interactively sudo may prompt, which beats a half-usable environment.
        if ! registry_resolves_locally "${REG_NAME}"; then
            RESOLVED="$(registry_resolved_addresses "${REG_NAME}")"
            if [ -n "${RESOLVED}" ]; then
                echo "  ${REG_NAME} resolves to ${RESOLVED}, not 127.0.0.1 — adding a hosts entry that takes precedence."
            fi
            if [ -w /etc/hosts ] || [ "$(id -u)" = "0" ]; then
                echo "127.0.0.1 ${REG_NAME}" >> /etc/hosts
                echo "  Added ${REG_NAME} to /etc/hosts."
            elif can_sudo; then
                echo "  Adding ${REG_NAME} to /etc/hosts (sudo may ask for your password; Ctrl-C skips just this step)..."
                # Ignore SIGINT here so cancelling the password prompt skips the
                # entry instead of aborting the whole setup.
                trap '' INT
                _hosts_written=false
                echo "127.0.0.1 ${REG_NAME}" | kind_sudo tee -a /etc/hosts >/dev/null && _hosts_written=true
                trap - INT
                if [ "${_hosts_written}" = true ]; then
                    echo "  Added ${REG_NAME} to /etc/hosts (via sudo)."
                else
                    echo "  Warning: could not write /etc/hosts; ${REG_NAME} stays unresolvable from the host."
                    echo "  dev-build and dev-deploy still work; dev-olm-* and dev-bundle-run will not."
                    echo "  Run: echo '127.0.0.1 ${REG_NAME}' | sudo tee -a /etc/hosts"
                fi
            else
                echo "  Warning: ${REG_NAME} is not in /etc/hosts and we don't have write access."
                echo "  dev-build and dev-deploy still work; dev-olm-* and dev-bundle-run will not."
                echo "  Run: echo '127.0.0.1 ${REG_NAME}' | sudo tee -a /etc/hosts"
            fi
        else
            echo "  ${REG_NAME} already resolves to loopback from the host."
        fi

        # Configure Docker to allow HTTP (insecure) access to the registry.
        # Must happen before Kind cluster creation since Docker restart kills containers.
        if [ "${CONTAINER_TOOL}" = "docker" ]; then
            DAEMON_JSON="/etc/docker/daemon.json"
            INSECURE_ENTRY="${REG_NAME}:${REG_PORT}"
            # Ask the running daemon, not daemon.json: the file may be present
            # but unapplied, and loopback registries are insecure by default.
            if docker_registry_is_insecure "${INSECURE_ENTRY}"; then
                echo "  Docker already allows HTTP pushes to ${INSECURE_ENTRY}."
            else
                _write_daemon_json() {
                    local target="$1"
                    if [ -f "${target}" ] && [ -s "${target}" ]; then
                        python3 -c "
import json,sys
d=json.load(open('${target}'))
r=d.get('insecure-registries',[])
e='${INSECURE_ENTRY}'
if e not in r: r.append(e)
d['insecure-registries']=r
json.dump(d,sys.stdout,indent=2)
" > "${target}.tmp" && mv "${target}.tmp" "${target}"
                    else
                        echo "{\"insecure-registries\": [\"${INSECURE_ENTRY}\"]}" > "${target}"
                    fi
                }
                NEED_DOCKER_RESTART=false
                if [ -w "${DAEMON_JSON}" ] || [ "$(id -u)" = "0" ]; then
                    _write_daemon_json "${DAEMON_JSON}"
                    NEED_DOCKER_RESTART=true
                elif can_sudo; then
                    echo "  Configuring ${DAEMON_JSON} (sudo may ask for your password; Ctrl-C skips just this step)..."
                    TMP_DJ=$(mktemp)
                    # See the /etc/hosts step: cancelling sudo skips this, it
                    # does not abort setup.
                    trap '' INT
                    if [ -f "${DAEMON_JSON}" ]; then
                        kind_sudo cp "${DAEMON_JSON}" "${TMP_DJ}" && chmod 644 "${TMP_DJ}"
                    fi
                    _write_daemon_json "${TMP_DJ}"
                    _daemon_written=false
                    kind_sudo cp "${TMP_DJ}" "${DAEMON_JSON}" && _daemon_written=true
                    trap - INT
                    if [ "${_daemon_written}" = true ]; then
                        NEED_DOCKER_RESTART=true
                    else
                        echo "  Warning: could not write ${DAEMON_JSON}; pushes to ${INSECURE_ENTRY} will fail over HTTP."
                        echo "  Run: echo '{\"insecure-registries\": [\"${INSECURE_ENTRY}\"]}' | sudo tee ${DAEMON_JSON} && sudo systemctl restart docker"
                    fi
                    rm -f "${TMP_DJ}"
                else
                    echo "  Warning: Cannot configure Docker insecure registries (no write access)."
                    echo "  Run: echo '{\"insecure-registries\": [\"${INSECURE_ENTRY}\"]}' | sudo tee ${DAEMON_JSON} && sudo systemctl restart docker"
                fi
                if [ "${NEED_DOCKER_RESTART}" = true ]; then
                    if [ "$(id -u)" = "0" ]; then
                        systemctl restart docker 2>/dev/null || true
                    else
                        kind_sudo systemctl restart docker 2>/dev/null || true
                    fi
                    echo "  Configured Docker insecure registry for ${INSECURE_ENTRY}."
                fi
            fi
        fi
    fi

    # inotify limits and rootless podman cgroup delegation are verified by
    # preflight_run above, before anything is created.

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
        echo "=== Creating Kind cluster '${CLUSTER_NAME}' ==="
        if [ "${KIND_BLOCK_STORAGE}" = true ]; then
            kind_block_prepare
        fi

        EFFECTIVE_KIND_CONFIG="${KIND_CONFIG}"
        if [ "${SETUP_DOCKER_SOCKET:-false}" = "true" ]; then
            echo "WARNING: SETUP_DOCKER_SOCKET exposes the host container runtime socket to each control-plane node." >&2
            echo "  Socket access allows container escape and is host-root-equivalent for rootful Docker/Podman." >&2
            echo "  For rootless runtimes, it grants the runtime user's host privileges. Use only in isolated, trusted dev/CI environments." >&2
            echo "  Adding docker.sock extraMounts to kind config for control-plane node..."
            EFFECTIVE_KIND_CONFIG=$(mktemp)
            trap 'rm -f "${EFFECTIVE_KIND_CONFIG}"' EXIT
            # Host socket path: from CONTAINER_SOCKET_PATH env (supports Podman) or default Docker path.
            # Always mounted at /var/run/docker.sock inside the node so the Deployment patch is static.
            HOST_SOCK="${CONTAINER_SOCKET_PATH:-/var/run/docker.sock}"
            python3 - "${KIND_CONFIG}" "${EFFECTIVE_KIND_CONFIG}" "${HOST_SOCK}" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    sys.exit(
        "Error: SETUP_DOCKER_SOCKET=true requires PyYAML for python3.\n"
        "Install your OS's python3-yaml package, or run 'python3 -m pip install PyYAML' "
        "in an activated virtual environment, then rerun setup."
    )
src, dst, host_sock = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    cfg = yaml.safe_load(f)
nodes = cfg.setdefault('nodes', [])
for node in nodes:
    if node.get('role') == 'control-plane':
        mounts = node.setdefault('extraMounts', [])
        sock_mount = {'hostPath': host_sock, 'containerPath': '/var/run/docker.sock'}
        if sock_mount not in mounts:
            mounts.append(sock_mount)
with open(dst, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
PYEOF
        fi
        kind create cluster --config "${EFFECTIVE_KIND_CONFIG}" --name "${CLUSTER_NAME}"
    else
        if [ "${KIND_BLOCK_STORAGE}" = true ]; then
            echo "Refusing to retrofit block storage onto an existing cluster. Run dev-teardown first." >&2
            exit 1
        fi
        echo "=== Cluster '${CLUSTER_NAME}' already exists — skipping creation, re-applying configuration ==="
    fi

    # Create local registry for OLM bundle deployment (unless skipped).
    # The registry runs as a container on the host and is connected to the Kind
    # network so that Kind nodes can pull images from it.
    if [ "${SKIP_REGISTRY}" != true ]; then
        echo "=== Setting up local registry '${REG_NAME}:${REG_PORT}' ==="
        if ${CONTAINER_TOOL} inspect "${REG_NAME}" &>/dev/null; then
            echo "  Registry container '${REG_NAME}' already exists."
        else
            ${CONTAINER_TOOL} run -d --restart=always \
                -p "127.0.0.1:${REG_PORT}:5000" \
                --network bridge \
                --name "${REG_NAME}" \
                docker.io/library/registry:2
            echo "  Registry container '${REG_NAME}' started on port ${REG_PORT}."
        fi

        # Connect registry to the kind network so nodes can reach it by container name.
        ${CONTAINER_TOOL} network connect kind "${REG_NAME}" 2>/dev/null || true

        # Get the registry's IP on the kind network for node /etc/hosts entries.
        # Nodes inherit the host's /etc/hosts (which maps kind-registry to 127.0.0.1),
        # but inside the node 127.0.0.1 is the node itself, not the registry.
        # shellcheck disable=SC2016  # Go template syntax; $net/$conf are not shell variables
        REG_IP=$(${CONTAINER_TOOL} inspect "${REG_NAME}" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{if eq $net "kind"}}{{$conf.IPAddress}}{{end}}{{end}}' 2>/dev/null)
        if [ -z "${REG_IP}" ]; then
            echo "  Warning: could not determine registry IP on kind network, falling back to container name."
            REG_IP="${REG_NAME}"
        fi

        # Configure containerd on each node to use the local registry (insecure/HTTP).
        # Also fix /etc/hosts so kind-registry resolves to the registry container's
        # kind-network IP, not 127.0.0.1 (which is inherited from the host).
        NODES_FOR_REG=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null)
        for node in ${NODES_FOR_REG}; do
            ${CONTAINER_TOOL} exec "$node" mkdir -p "/etc/containerd/certs.d/${REG_NAME}:${REG_PORT}"
            ${CONTAINER_TOOL} exec "$node" bash -c "cat <<EOF >/etc/containerd/certs.d/${REG_NAME}:${REG_PORT}/hosts.toml
[host.\"http://${REG_NAME}:${REG_PORT}\"]
EOF"
            # Fix /etc/hosts: remove any 127.0.0.1 entry for the registry and add the correct IP.
            # Use cp instead of sed -i because /etc/hosts is a mount and can't be renamed.
            ${CONTAINER_TOOL} exec "$node" bash -c "grep -v '127.0.0.1.*${REG_NAME}' /etc/hosts > /tmp/hosts.new && echo '${REG_IP} ${REG_NAME}' >> /tmp/hosts.new && cp /tmp/hosts.new /etc/hosts && rm /tmp/hosts.new"
        done
        echo "  Containerd configured on all nodes to use ${REG_NAME}:${REG_PORT} (IP: ${REG_IP})."
    fi

    echo "=== Waiting for all nodes to be Ready ==="
    # 'wait --all' only covers the nodes already registered, so a worker that
    # joins a moment later is missed — and then misses its role label too.
    # Wait for every Kind node container to show up in the API first.
    EXPECTED_NODES=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep -c . || true)
    if [ "${EXPECTED_NODES}" -gt 0 ]; then
        for _ in $(seq 1 60); do
            REGISTERED=$(${KUBECTL} get nodes --no-headers 2>/dev/null | grep -c . || true)
            [ "${REGISTERED}" -ge "${EXPECTED_NODES}" ] && break
            sleep 2
        done
        REGISTERED=$(${KUBECTL} get nodes --no-headers 2>/dev/null | grep -c . || true)
        if [ "${REGISTERED}" -lt "${EXPECTED_NODES}" ]; then
            echo "  Warning: only ${REGISTERED} of ${EXPECTED_NODES} nodes registered with the API server."
        fi
    fi
    ${KUBECTL} wait --for=condition=Ready node --all --timeout=120s

    echo "=== Labeling worker nodes ==="
    # Label any non-CP nodes with the worker role (idempotent)
    LABELED=0
    for node in $(${KUBECTL} get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
        if ! ${KUBECTL} get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'node-role.kubernetes.io/control-plane'; then
            if ${KUBECTL} get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'node-role.kubernetes.io/worker'; then
                continue
            fi
            if ${KUBECTL} label node "$node" node-role.kubernetes.io/worker="" >/dev/null 2>&1; then
                echo "  labeled $node"
                LABELED=$((LABELED + 1))
            else
                echo "  Warning: could not label $node as a worker; NodeHealthCheck selects on node-role.kubernetes.io/worker."
            fi
        fi
    done
    if [ "${LABELED}" -eq 0 ]; then
        echo "  All worker nodes already labeled."
    fi

    # Optional: per-node null-backed /dev/watchdog for SBR multi-node e2e in Kind.
    # The real softdog device is single-open; SBR needs every node's agent to hold
    # its own watchdog concurrently. Set SETUP_NULL_DEVICE_WATCHDOG=true to enable.
    if [ "${SETUP_NULL_DEVICE_WATCHDOG:-false}" = "true" ]; then
        echo "=== Setting up per-node null-device /dev/watchdog (SETUP_NULL_DEVICE_WATCHDOG=true) ==="
        "${SCRIPT_DIR}/setup-null-device-watchdog.sh"
    fi

    echo "=== Loading softdog kernel module on worker nodes (for SNR/SBR watchdog) ==="
    echo "  Using soft_noboot=1 so the watchdog fires harmlessly (no real reboot)."
    echo "  The reboot watcher (make dev-reboot-watcher) handles Kind container restarts."
    NODES=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null)
    if [ -z "${NODES}" ]; then
        NODES=$(${KUBECTL} get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
    fi
    for node in ${NODES}; do
        if echo "$node" | grep -q 'worker'; then
            ${CONTAINER_TOOL} exec "$node" modprobe softdog soft_noboot=1 2>/dev/null && \
                echo "  softdog (noboot) loaded on $node" || \
                echo "  Warning: could not load softdog on $node (SNR/SBR watchdog reboot testing will be limited)"
        fi
    done

    # Optional: RWX NFS filesystem StorageClass for SBR filesystem-mode e2e in Kind.
    # Requires the nfsd kernel module on the host. Set SETUP_NFS_RWX=true to enable.
    if [ "${SETUP_NFS_RWX:-false}" = "true" ]; then
        echo "=== Setting up RWX NFS filesystem StorageClass (SETUP_NFS_RWX=true) ==="
        "${SCRIPT_DIR}/setup-nfs-rwx.sh"
    fi

    if [ "${KIND_BLOCK_STORAGE}" = true ]; then
        echo "=== Setting up Kind Block Storage ==="
        kind_block_install
    fi 

    if [ "${SETUP_MDR_MOCK:-false}" = true ]; then
        echo "=== Setting up Machine API fixtures (SETUP_MDR_MOCK=true) ==="
        CONTAINER_TOOL="${CONTAINER_TOOL}" KUBECTL="${KUBECTL}" \
            python3 "${SCRIPT_DIR}/kind_mdr.py" prepare --name "${CLUSTER_NAME}" --crd-dir "${MDR_CRD_DIR}"
    fi
    
    # Optional: verify docker.sock is accessible on the control-plane node.
    # The socket is mounted at cluster-creation time via extraMounts (see above).
    if [ "${SETUP_DOCKER_SOCKET:-false}" = "true" ]; then
        echo "=== Verifying /var/run/docker.sock on control-plane node (SETUP_DOCKER_SOCKET=true) ==="
        CP_NODE=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep control-plane | head -1)
        if [ -z "${CP_NODE}" ]; then
            CP_NODE=$(${KUBECTL} get nodes -l node-role.kubernetes.io/control-plane --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
        fi
        if [ -n "${CP_NODE}" ]; then
            if ${CONTAINER_TOOL} exec "${CP_NODE}" test -S /var/run/docker.sock 2>/dev/null; then
                echo "  /var/run/docker.sock is accessible on ${CP_NODE}."
            else
                echo "  Warning: /var/run/docker.sock is not a socket on ${CP_NODE}."
                echo "  If this is an existing cluster, delete it and re-run setup with SETUP_DOCKER_SOCKET=true."
            fi
        else
            echo "  Warning: could not find control-plane node."
        fi
    fi
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

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"
if ! [[ "${CERT_MANAGER_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: CERT_MANAGER_VERSION must be a semver tag (e.g. v1.17.2), got: '${CERT_MANAGER_VERSION}'"
    exit 1
fi
echo "=== Installing cert-manager ${CERT_MANAGER_VERSION} ==="
if ${KUBECTL} get crd certificates.cert-manager.io &>/dev/null; then
    echo "  cert-manager already installed (CRDs found)."
else
    ${KUBECTL} apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    echo "  Waiting for cert-manager to be ready..."
    ${KUBECTL} wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

    # --- ADDED: Webhook buffer to prevent OLM deadlock ---
    echo "  Waiting for Cert-Manager webhook to stabilize in the API server..."
    sleep 15
    ${KUBECTL} wait --for=condition=Ready pod -l app.kubernetes.io/component=webhook -n cert-manager --timeout=120s
    # -----------------------------------------------------
fi

if [ "$INSTALL_OLM" = true ]; then
    if command -v operator-sdk &>/dev/null; then
        echo "=== Installing OLM ==="
        # --- ADDED: 5m timeout so it fails gracefully instead of hanging forever ---
        operator-sdk olm install --timeout 5m 2>/dev/null || {
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
SUMMARY_WARNINGS=()

NODE_TOTAL=$(${KUBECTL} get nodes --no-headers 2>/dev/null | grep -c . || true)
NODE_CP=$(${KUBECTL} get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | grep -c . || true)
NODE_WORKERS=$(${KUBECTL} get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c . || true)
NODE_LINE="${NODE_TOTAL} (${NODE_CP} CP + ${NODE_WORKERS} workers)"
if [ "${NODE_WORKERS}" -eq 0 ] && [ "${NODE_TOTAL}" -gt "${NODE_CP}" ]; then
    NODE_LINE="${NODE_LINE}  [WARN]"
    SUMMARY_WARNINGS+=("$((NODE_TOTAL - NODE_CP)) node(s) carry no node-role.kubernetes.io/worker label. NodeHealthCheck and 'make dev-simulate-failure' select on it — re-run 'make dev-setup' to label them.")
fi

# Registry state: running, and resolvable from the host (the OLM targets push
# and render under that hostname from here).
if [ "${SKIP_KIND}" = true ]; then
    # No local registry is created for a session cluster; images reach it over
    # the network (DEV_REGISTRY defaults to ttl.sh for external clusters).
    REG_LINE="not used — images are delivered per DEV_REGISTRY (default ttl.sh for external clusters)"
elif [ "${SKIP_REGISTRY}" = true ]; then
    REG_LINE="disabled (SKIP_REGISTRY=true)"
elif ! ${CONTAINER_TOOL} inspect "${REG_NAME}" >/dev/null 2>&1; then
    REG_LINE="not running  [WARN]"
    SUMMARY_WARNINGS+=("Registry container '${REG_NAME}' is not running; 'make dev-build' with DEV_REGISTRY=registry cannot push.")
elif ! getent hosts "${REG_NAME}" >/dev/null 2>&1; then
    REG_LINE="${REG_NAME}:${REG_PORT}  [WARN: not resolvable from host]"
    SUMMARY_WARNINGS+=("'${REG_NAME}' does not resolve on the host: dev-build and dev-deploy work (they push to localhost:${REG_PORT}), but dev-olm-* and dev-bundle-run do not. Fix: echo '127.0.0.1 ${REG_NAME}' | sudo tee -a /etc/hosts")
else
    REG_LINE="${REG_NAME}:${REG_PORT}"
fi

NEW_CONTEXT=$(${KUBECTL} config current-context 2>/dev/null || true)
if [ "${SKIP_KIND}" = true ]; then
    echo "  Cluster:   ${NEW_CONTEXT:-<current context>} (your kubeconfig session)"
else
    echo "  Cluster:   ${CLUSTER_NAME} (Kind)"
    if [ -n "${CURRENT_CONTEXT:-}" ] && [ "${CURRENT_CONTEXT}" != "${NEW_CONTEXT}" ]; then
        SUMMARY_WARNINGS+=("kubectl context switched from '${CURRENT_CONTEXT}' to '${NEW_CONTEXT}'. Restore it with: ${KUBECTL} config use-context ${CURRENT_CONTEXT}")
    fi
fi
echo "  Namespace: ${DEV_NS}"
echo "  Nodes:     ${NODE_LINE}"
echo "  Registry:  ${REG_LINE}"
echo "  OLM:       $(${KUBECTL} get deployment -n olm olm-operator --no-headers >/dev/null 2>&1 && echo 'installed' || echo 'not installed')"
if [ ${#SUMMARY_WARNINGS[@]} -gt 0 ]; then
    echo ""
    echo "  Warnings (${#SUMMARY_WARNINGS[@]}):"
    for warning in "${SUMMARY_WARNINGS[@]}"; do
        echo "    - ${warning}"
    done
fi
echo ""
echo "  Next steps:"
echo "    cd <operator-directory>"
echo "    make dev-deploy              # Build and deploy operator"
echo "    make dev-simulate-failure    # Trigger node failure"
echo "    make dev-logs                # Watch operator logs"
echo "    make dev-describe            # Check cluster state"
echo ""
