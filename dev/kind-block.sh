#!/usr/bin/env bash
# Sourced by setup.sh and teardown.sh only when KIND_BLOCK_STORAGE=true.
# One disposable Linux loop device is shared by all Kind worker containers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

kind_block_state() {
    [[ "$CLUSTER_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        echo "Invalid Kind cluster name: $CLUSTER_NAME" >&2; return 1;
    }
    KIND_BLOCK_STATE_DIR=${KIND_BLOCK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/medik8s/kind-block/$CLUSTER_NAME}
    [[ "$KIND_BLOCK_STATE_DIR" == /* ]] || {
        echo "KIND_BLOCK_STATE_DIR must be an absolute path." >&2; return 1;
    }
    export KUBECONFIG="$KIND_BLOCK_STATE_DIR/kubeconfig"
    if [[ -f "$KIND_BLOCK_STATE_DIR/owned" ]]; then
        [[ $(cat "$KIND_BLOCK_STATE_DIR/owned") == "$CLUSTER_NAME" ]] || {
            echo "Block state belongs to another cluster." >&2; return 1;
        }
    fi
}

kind_block_check_host() {
    local tool="${CONTAINER_TOOL:-docker}"
    [[ $(uname -s) == Linux && ( "$tool" == docker || "$tool" == podman ) ]] || {
        echo "Kind block storage requires Linux and CONTAINER_TOOL=docker or podman." >&2; return 1;
    }
    
    local cmd endpoint security_options operating_system
    for cmd in "$tool" losetup truncate; do command -v "$cmd" >/dev/null || return 1; done
    kind_sudo true
    
    if [[ "$tool" == "docker" ]]; then
        if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
            endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
        else
            endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo "unix:///var/run/docker.sock")}
        fi
        [[ "$endpoint" == unix://* ]] || {
            echo "Host loop devices require a local Docker socket." >&2; return 1;
        }
        operating_system=$(docker info --format '{{.OperatingSystem}}')
        security_options=$(docker info --format '{{json .SecurityOptions}}')
        if [[ "$operating_system" == *"Docker Desktop"* || "$security_options" == *rootless* ]]; then
            echo "Kind block storage requires native, rootful Docker." >&2; return 1
        fi
    elif [[ "$tool" == "podman" ]]; then
        operating_system=$(podman info --format '{{.Host.Distribution.Distribution}}')
        # Podman Machine uses a lightweight VM, meaning host loop devices won't map into the container natively.
        if [[ "$operating_system" == *"Podman Machine"* ]]; then
            echo "Kind block storage requires native Linux Podman." >&2; return 1
        fi
    fi
}

kind_block_prepare() {
    [[ ! -e "$KIND_BLOCK_STATE_DIR/owned" && ! -e "$KIND_BLOCK_STATE_DIR/block.img" ]] || {
        echo "Unfinished block environment: run dev-teardown with the same block settings first." >&2; return 1;
    }
    mkdir -p "$KIND_BLOCK_STATE_DIR"
    printf '%s\n' "$CLUSTER_NAME" > "$KIND_BLOCK_STATE_DIR/owned"
    truncate -s 64M "$KIND_BLOCK_STATE_DIR/block.img"
    
    # Create loop device with direct-io enabled
    kind_sudo losetup --find --direct-io=on --show "$KIND_BLOCK_STATE_DIR/block.img" > "$KIND_BLOCK_STATE_DIR/loop-device"
    
    local device cp_count=1 index
    device=$(cat "$KIND_BLOCK_STATE_DIR/loop-device")
    [[ "$device" =~ ^/dev/loop[0-9]+$ ]] || { echo "Unexpected loop device: $device" >&2; return 1; }
    
    # Grant unprivileged host user ownership of loop device
    if [[ $(id -u) -ne 0 ]]; then
        kind_sudo chown "$(id -u):$(id -g)" "$device"
    fi

    [[ "${KIND_HA:-false}" != true ]] || cp_count=3
    
    local pod_subnet="${KIND_POD_SUBNET:-10.244.0.0/16}"
    local svc_subnet="${KIND_SERVICE_SUBNET:-10.96.0.0/16}"

    KIND_CONFIG="$KIND_BLOCK_STATE_DIR/kind.yaml"
    {
        cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  podSubnet: "${pod_subnet}"
  serviceSubnet: "${svc_subnet}"
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
EOF
        for ((index=0; index<cp_count; index++)); do echo '- role: control-plane'; done
        for index in 1 2; do
            cat <<EOF
- role: worker
  labels:
    medik8s.io/kind-block: "true"
  extraMounts:
  - hostPath: $device
    containerPath: /dev/medik8s-kind-block
EOF
        done
    } > "$KIND_CONFIG"
}

kind_block_install() {
    local node nodes tool="${CONTAINER_TOOL:-docker}"
    [[ $(${KUBECTL} config current-context) == "kind-$CLUSTER_NAME" ]] || {
        echo "Refusing to install storage outside kind-$CLUSTER_NAME." >&2; return 1;
    }
    nodes=$(${KUBECTL} get nodes -l medik8s.io/kind-block=true -o name)
    [[ $(wc -w <<< "$nodes") == 2 ]] || { echo "Expected two block-enabled workers." >&2; return 1; }

    for node in $nodes; do
        "$tool" exec "${node#node/}" test -e /dev/medik8s-kind-block || {
            echo "Device /dev/medik8s-kind-block missing on ${node#node/}" >&2
            return 1
        }
    done

    ${KUBECTL} apply -f "$SCRIPT_DIR/kind-block-storage.yaml"
    echo "Shared raw block storage ready: StorageClass medik8s-kind-block (64 MiB)."
    echo "Kubeconfig: $KUBECONFIG"
}

kind_block_cleanup() {
    [[ -f "$KIND_BLOCK_STATE_DIR/owned" ]] || return 0
    # Called only AFTER Kind has removed every node. A failed lookup/detach
    # must preserve the backing file and ownership marker for a cleanup retry.
    local devices device containers tool="${CONTAINER_TOOL:-docker}"
    containers=$("$tool" ps -aq --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME")
    [[ -z "$containers" ]] || { echo "Kind nodes still exist; refusing to detach block storage." >&2; return 1; }
    devices=$(kind_sudo losetup --associated "$KIND_BLOCK_STATE_DIR/block.img" --noheadings --output NAME)
    while read -r device; do
        [[ -z "$device" ]] || kind_sudo losetup --detach "$device"
    done <<< "$devices"
    rm -f "$KIND_BLOCK_STATE_DIR/block.img" "$KIND_BLOCK_STATE_DIR/loop-device" \
        "$KIND_BLOCK_STATE_DIR/owned" "$KIND_BLOCK_STATE_DIR/kubeconfig"
}
