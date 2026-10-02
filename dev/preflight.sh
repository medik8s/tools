#!/bin/bash
# Preflight checks for the medik8s dev environment.
#
# Everything that needs host privileges or host configuration is checked here,
# before anything is created, so a missing permission is reported with the fix
# instead of surfacing as a cryptic kind/kubelet failure halfway through setup.
#
# Sourced by setup.sh (preflight_run) and run directly by 'make dev-preflight'.
#
# Honors the same environment as setup.sh: CONTAINER_TOOL, MEDIK8S_CLUSTER_NAME,
# SKIP_KIND, SKIP_REGISTRY, MEDIK8S_REGISTRY_NAME/PORT, KIND_BLOCK_STORAGE,
# SETUP_DOCKER_SOCKET, SETUP_NULL_DEVICE_WATCHDOG, SETUP_NFS_RWX.

PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${PREFLIGHT_DIR}/common.sh"

PF_FAILED=0
PF_WARNED=0
PF_PENDING=0
# Steps that go through kind_sudo, which uses 'sudo -n' and cannot prompt.
PF_PRIVILEGED_STEPS=()

# Phrase the host-config checks the way setup.sh will actually behave: it
# prompts for sudo interactively (can_sudo, from common.sh) and only degrades
# to a manual instruction when even that is unavailable.
pf_sudo_note() {
    [ "$(id -u)" = 0 ] && return 0
    sudo -n true 2>/dev/null || echo " — sudo will ask for your password"
}

pf_detail() {
    local line
    for line in "$@"; do
        printf '         %s\n' "${line}"
    done
}

pf_ok() { printf '  [ok]   %s\n' "$1"; }

pf_skip() { printf '  [--]   %s\n' "$1"; }

pf_warn() {
    PF_WARNED=$((PF_WARNED + 1))
    printf '  [warn] %s\n' "$1"
    pf_detail "${@:2}"
}

# Not OK yet: a host change dev-setup still has to make, possibly asking for a
# password. Reported separately so a clean run never claims it is already fine.
pf_todo() {
    PF_PENDING=$((PF_PENDING + 1))
    printf '  [todo] %s\n' "$1"
    pf_detail "${@:2}"
}

pf_fail() {
    PF_FAILED=$((PF_FAILED + 1))
    printf '  [FAIL] %s\n' "$1"
    pf_detail "${@:2}"
}

# The other runtime. Most host-permission problems affect only one of them, so
# every blocking check offers "fix this, or use that instead".
pf_other_tool() {
    [ "${CONTAINER_TOOL}" = podman ] && echo docker || echo podman
}

# Prints a "use the other tool" line, but only when that tool actually responds.
# Empty output otherwise, so callers can splice it in with ${var:+"$var"}.
pf_other_tool_line() {
    local other
    other="$(pf_other_tool)"
    container_tool_works "${other}" || return 0
    echo "Or use ${other}, which is working on this host${1:+ and ${1}}: CONTAINER_TOOL=${other} make dev-setup"
}

# Container tool is installed and its daemon answers.
pf_check_container_tool() {
    if container_tool_works "${CONTAINER_TOOL}"; then
        if [ "${CONTAINER_TOOL}" = podman ] && [ "$(id -u)" != 0 ]; then
            pf_ok "container tool: ${CONTAINER_TOOL} (rootless)"
        else
            pf_ok "container tool: ${CONTAINER_TOOL}"
        fi
    else
        local other alt
        other="$(pf_other_tool)"
        if container_tool_works "${other}"; then
            alt="Use ${other} instead: CONTAINER_TOOL=${other} make dev-setup"
        else
            alt="${other} is not usable either: $(container_tool_hint "${other}")"
        fi
        pf_fail "container tool: $(container_tool_hint "${CONTAINER_TOOL}")" "${alt}"
    fi
}

# Rootless podman needs a working user namespace and cgroup v2 with 'cpuset'
# delegated; without either, Kind nodes start but kubelet never comes up.
pf_check_rootless_podman() {
    if [ "${CONTAINER_TOOL}" != podman ] || [ "$(id -u)" = 0 ]; then
        return
    fi

    local alt
    alt="$(pf_other_tool_line "needs none of this rootless setup")"

    if podman unshare true 2>/dev/null; then
        pf_ok "rootless podman: user namespace usable"
    else
        pf_fail "rootless podman: cannot enter a user namespace ('podman unshare' failed)" \
            "Usually missing subuid/subgid ranges. Fix:" \
            "  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)" \
            "  podman system migrate" \
            ${alt:+"${alt}"}
    fi

    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        pf_fail "rootless podman: cgroup v2 is required (host is on cgroup v1)" \
            "Boot with systemd.unified_cgroup_hierarchy=1." \
            ${alt:+"${alt}"}
        return
    fi

    local uid subtree
    uid="$(id -u)"
    subtree="/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/cgroup.subtree_control"
    if [ ! -f "${subtree}" ]; then
        pf_skip "rootless podman: cgroup delegation not verifiable (no ${subtree})"
    elif grep -q cpuset "${subtree}" 2>/dev/null; then
        pf_ok "rootless podman: cpuset cgroup controller delegated"
    else
        pf_fail "rootless podman: 'cpuset' cgroup controller is not delegated — kubelet cannot start in Kind nodes" \
            "Fix:" \
            "  sudo mkdir -p /etc/systemd/system/user@.service.d" \
            "  sudo tee /etc/systemd/system/user@.service.d/delegate.conf << \"EOF\"" \
            "  [Service]" \
            "  Delegate=cpu cpuset io memory pids" \
            "  EOF" \
            "  sudo systemctl daemon-reload" \
            "Then log out and log back in — 'systemctl --user restart' is NOT enough," \
            "the user@.service unit is only re-read at login." \
            ${alt:+"${alt}"} \
            "Or create the cluster as root with" \
            "  sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --name ${CLUSTER_NAME}" \
            "  sudo kind get kubeconfig --name ${CLUSTER_NAME} > ~/.kube/config"
    fi
}

# Kind nodes inherit the host inotify limits; operators exhaust the defaults.
# Running as root, setup.sh raises them in place (PF_AUTO_FIX_INOTIFY=true);
# a direct 'make dev-preflight' only reports, so it stays read-only.
pf_check_inotify() {
    if [ "$(uname -s)" != Linux ]; then
        pf_skip "inotify limits: not checked (non-Linux host)"
        return
    fi
    if [ "${PF_SKIP_INOTIFY}" = true ]; then
        pf_warn "inotify limits: check skipped — nodes may fail to start if the limits are too low"
        return
    fi

    local instances watches
    instances=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
    watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
    if [ "${instances}" -ge 512 ] && [ "${watches}" -ge 524288 ]; then
        pf_ok "inotify limits: instances=${instances}, watches=${watches}"
        return
    fi

    if [ "$(id -u)" = 0 ] && [ "${PF_AUTO_FIX_INOTIFY}" = true ]; then
        if sysctl -w fs.inotify.max_user_instances=8192 >/dev/null &&
           sysctl -w fs.inotify.max_user_watches=524288 >/dev/null; then
            pf_ok "inotify limits: raised automatically (running as root)"
        else
            pf_fail "inotify limits: could not raise them even as root" \
                "Check 'sysctl -w fs.inotify.max_user_instances=8192' manually."
        fi
        return
    fi

    pf_fail "inotify limits are too low: instances=${instances}, watches=${watches} (need 512 / 524288)" \
        "Fix (requires sudo):" \
        "  sudo sysctl -w fs.inotify.max_user_instances=8192" \
        "  sudo sysctl -w fs.inotify.max_user_watches=524288" \
        "Persist in /etc/sysctl.d/99-kind.conf:" \
        "  fs.inotify.max_user_instances=8192" \
        "  fs.inotify.max_user_watches=524288" \
        "Skip this check with --skip-inotify-check."
}

# Host-side registry wiring: /etc/hosts entry and, for docker, the insecure
# registry entry in daemon.json. Both are written by setup.sh when it can.
pf_check_registry_host_config() {
    if [ "${SKIP_REGISTRY}" = true ]; then
        pf_skip "local registry: disabled (SKIP_REGISTRY=true)"
        return
    fi

    # The registry listens on 127.0.0.1 only, so loopback resolution is the
    # requirement — a name that resolves elsewhere sends pushes to that host.
    local resolved problem
    resolved="$(registry_resolved_addresses "${REG_NAME}")"
    if registry_resolves_locally "${REG_NAME}"; then
        pf_ok "local registry: ${REG_NAME} resolves to loopback (${resolved})"
    else
        if [ -z "${resolved}" ]; then
            problem="${REG_NAME} does not resolve on the host"
        else
            problem="${REG_NAME} resolves to ${resolved}, but the registry only listens on 127.0.0.1:${REG_PORT}"
        fi
        if [ -w /etc/hosts ] || can_sudo; then
            # An /etc/hosts entry also wins over a stray DNS answer.
            pf_todo "local registry: ${problem}; dev-setup will add '127.0.0.1 ${REG_NAME}' to /etc/hosts$(pf_sudo_note)"
        else
            # Not fatal: the nodes get their own hosts entry from setup.sh and
            # dev-build pushes to localhost, so only host-side OLM work breaks.
            pf_warn "local registry: ${problem}, and /etc/hosts is not writable" \
                "dev-build and dev-deploy still work (they push to localhost:${REG_PORT})." \
                "The OLM targets do not: dev-olm-* and dev-bundle-run push and render ${REG_NAME}:${REG_PORT} from the host." \
                "Fix: echo '127.0.0.1 ${REG_NAME}' | sudo tee -a /etc/hosts" \
                "Or run those targets with DEV_REGISTRY=ttl.sh."
        fi
    fi

    # Only docker needs daemon-level configuration; podman pushes with
    # --tls-verify=false and the nodes are configured by setup.sh.
    if [ "${CONTAINER_TOOL}" != docker ]; then
        return
    fi

    local daemon_json=/etc/docker/daemon.json entry="${REG_NAME}:${REG_PORT}"
    if docker_registry_is_insecure "${entry}"; then
        pf_ok "local registry: the running docker daemon allows HTTP pushes to ${entry}"
    elif [ -w "${daemon_json}" ] || can_sudo; then
        pf_todo "local registry: ${entry} is not allowed over HTTP yet; dev-setup will add it to ${daemon_json} and restart docker$(pf_sudo_note)"
    else
        local alt
        alt="$(pf_other_tool_line "needs no daemon.json entry")"
        pf_warn "local registry: docker is not configured for insecure registry ${entry} and ${daemon_json} is not writable" \
            "Fix: echo '{\"insecure-registries\": [\"${entry}\"]}' | sudo tee ${daemon_json} && sudo systemctl restart docker" \
            ${alt:+"${alt}"} \
            "Or avoid the registry entirely: DEV_REGISTRY=local (kind load) or SKIP_REGISTRY=true."
    fi
}

# A session cluster pulls images over the network, so the local Kind registry
# is irrelevant — what matters is that the delivery method can reach it.
pf_check_image_delivery() {
    case "${DEV_REGISTRY:-}" in
        ttl.sh|"")
            pf_ok "images: pushed to ttl.sh (public, ephemeral); the cluster must be able to pull from ttl.sh"
            ;;
        registry)
            pf_warn "images: DEV_REGISTRY=registry means the local Kind registry, which this cluster cannot pull from" \
                "Use DEV_REGISTRY=ttl.sh, or a registry reachable from both this host and the cluster."
            ;;
        local)
            pf_fail "images: DEV_REGISTRY=local delivers with 'kind load', which does not work on a non-Kind cluster" \
                "Use DEV_REGISTRY=ttl.sh."
            ;;
        *)
            pf_ok "images: DEV_REGISTRY=${DEV_REGISTRY}"
            ;;
    esac
}

# Deploying installs CRDs, namespaces and (when missing) cert-manager, so a
# plain project-scoped login is not enough. Say so before anything is applied.
pf_check_cluster_permissions() {
    local missing=() resource
    for resource in namespaces customresourcedefinitions.apiextensions.k8s.io clusterroles.rbac.authorization.k8s.io; do
        ${KUBECTL} auth can-i create "${resource}" --quiet >/dev/null 2>&1 || missing+=("${resource%%.*}")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        pf_ok "cluster permissions: can create namespaces, CRDs and cluster roles"
    else
        pf_warn "cluster permissions: cannot create ${missing[*]} on this cluster" \
            "dev-setup and dev-deploy install cluster-scoped resources and will fail." \
            "Log in with an account that has cluster-admin, or use a Kind cluster: USE_KIND=true make dev-setup"
    fi
}

# Optional add-ons that touch the host.
pf_check_addons() {
    if [ "${KIND_BLOCK_STORAGE}" = true ]; then
        if [ "$(uname -s)" != Linux ]; then
            pf_fail "KIND_BLOCK_STORAGE: requires Linux (host is $(uname -s))"
        elif ! command -v losetup &>/dev/null; then
            pf_fail "KIND_BLOCK_STORAGE: 'losetup' not found" \
                "Install util-linux, or unset KIND_BLOCK_STORAGE."
        else
            PF_PRIVILEGED_STEPS+=("attach a loop device for shared block storage")
            pf_ok "KIND_BLOCK_STORAGE: losetup available (needs root for the loop device)"
        fi
    fi

    if [ "${SETUP_NULL_DEVICE_WATCHDOG}" = true ]; then
        pf_ok "SETUP_NULL_DEVICE_WATCHDOG: enabled (created inside the nodes, no host privileges)"
    fi

    if [ "${SETUP_NFS_RWX}" = true ]; then
        if [ -d /proc/fs/nfsd ] || lsmod 2>/dev/null | grep -q '^nfsd'; then
            pf_ok "SETUP_NFS_RWX: nfsd kernel module available"
        else
            pf_warn "SETUP_NFS_RWX: the nfsd kernel module is not loaded on the host" \
                "Fix: sudo modprobe nfsd nfs"
        fi
    fi

    if [ "${SETUP_DOCKER_SOCKET}" = true ]; then
        local sock="${CONTAINER_SOCKET_PATH:-/var/run/docker.sock}"
        if [ -S "${sock}" ] && [ -r "${sock}" ] && [ -w "${sock}" ]; then
            pf_ok "SETUP_DOCKER_SOCKET: ${sock} accessible"
        elif [ -S "${sock}" ]; then
            pf_fail "SETUP_DOCKER_SOCKET: ${sock} exists but $(id -un) cannot read/write it" \
                "Fix: add yourself to the 'docker' group, or point CONTAINER_SOCKET_PATH at a socket you own" \
                "  (podman: 'systemctl --user start podman.socket' then CONTAINER_SOCKET_PATH=/run/user/$(id -u)/podman/podman.sock)."
        else
            pf_fail "SETUP_DOCKER_SOCKET: no socket at ${sock}" \
                "Start the runtime socket, or set CONTAINER_SOCKET_PATH to its path."
        fi
    fi
}

# Does this tool's kind see the cluster? Containers belong to the runtime that
# created them, so this is the ownership test.
pf_cluster_listed() {
    KIND_EXPERIMENTAL_PROVIDER="$1" kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"
}

# Is the cluster already there? Like setup.sh, a cluster that only answers
# through its kubeconfig context counts (created with rootful podman, say).
pf_cluster_exists() {
    pf_cluster_listed "${CONTAINER_TOOL}" ||
        ${KUBECTL} cluster-info --context "kind-${CLUSTER_NAME}" --request-timeout=5s &>/dev/null
}

# An existing cluster belongs to whichever tool created it; using the other one
# silently creates a second cluster, and node commands ('make dev-shell',
# failure simulation) cannot see the containers.
pf_check_cluster_owner() {
    local other
    if pf_cluster_listed "${CONTAINER_TOOL}"; then
        pf_ok "cluster '${CLUSTER_NAME}': exists under ${CONTAINER_TOOL}"
        return
    fi
    other="$(pf_other_tool)"
    if container_tool_works "${other}" && pf_cluster_listed "${other}"; then
        pf_warn "cluster '${CLUSTER_NAME}' belongs to ${other}, but ${CONTAINER_TOOL} is selected" \
            "Node commands and image loading will not find its containers." \
            "Fix: re-run with CONTAINER_TOOL=${other}, or delete it with" \
            "  KIND_EXPERIMENTAL_PROVIDER=${other} kind delete cluster --name ${CLUSTER_NAME}"
    elif [ "${PF_CLUSTER_EXISTS}" = true ]; then
        pf_ok "cluster '${CLUSTER_NAME}': reachable through its kubeconfig context (created outside this user's ${CONTAINER_TOOL})"
    fi
}

# Steps that go through kind_sudo, which uses plain 'sudo' interactively and
# 'sudo -n' in CI or when stdin is not a terminal.
pf_check_sudo() {
    [ ${#PF_PRIVILEGED_STEPS[@]} -eq 0 ] && return
    [ "$(id -u)" = 0 ] && { pf_ok "privileged steps: running as root"; return; }

    local steps
    steps=$(printf '%s; ' "${PF_PRIVILEGED_STEPS[@]}")
    if ! command -v sudo &>/dev/null; then
        pf_fail "privileged steps needed but sudo is not installed: ${steps%; }"
    elif sudo -n true 2>/dev/null; then
        pf_ok "privileged steps: passwordless sudo available (${steps%; })"
    elif [ "${CI:-false}" = true ] || [ ! -t 0 ]; then
        pf_fail "privileged steps need sudo, but this shell is non-interactive and sudo requires a password: ${steps%; }" \
            "Fix: grant passwordless sudo, run as root, or disable the features that need it."
    else
        pf_warn "privileged steps: sudo will prompt for a password (${steps%; })"
    fi
}

# Run every check and summarize. Returns 1 when something must be fixed.
preflight_run() {
    PF_SKIP_INOTIFY="${PF_SKIP_INOTIFY:-false}"
    # Only setup.sh opts into changing the host; dev-preflight stays read-only.
    PF_AUTO_FIX_INOTIFY="${PF_AUTO_FIX_INOTIFY:-false}"
    CLUSTER_NAME="${CLUSTER_NAME:-${MEDIK8S_CLUSTER_NAME:-medik8s-dev}}"
    REG_NAME="${REG_NAME:-${MEDIK8S_REGISTRY_NAME:-kind-registry}}"
    REG_PORT="${REG_PORT:-${MEDIK8S_REGISTRY_PORT:-5000}}"
    SKIP_KIND="${SKIP_KIND:-false}"
    SKIP_REGISTRY="${SKIP_REGISTRY:-false}"
    KIND_BLOCK_STORAGE="${KIND_BLOCK_STORAGE:-false}"
    SETUP_DOCKER_SOCKET="${SETUP_DOCKER_SOCKET:-false}"
    SETUP_NULL_DEVICE_WATCHDOG="${SETUP_NULL_DEVICE_WATCHDOG:-false}"
    SETUP_NFS_RWX="${SETUP_NFS_RWX:-false}"

    echo "=== Preflight checks ==="
    pf_check_container_tool
    if [ "${SKIP_KIND}" = true ]; then
        pf_skip "Kind host checks: skipped (using the cluster from your kubeconfig)"
        pf_check_cluster_permissions
        pf_check_image_delivery
    else
        PF_CLUSTER_EXISTS=false
        if pf_cluster_exists; then PF_CLUSTER_EXISTS=true; fi
        # Node-creation requirements only matter while creating nodes: a cluster
        # built as root stays usable from an account without cgroup delegation.
        [ "${PF_CLUSTER_EXISTS}" = true ] || pf_check_rootless_podman
        pf_check_inotify
        pf_check_cluster_owner
        pf_check_registry_host_config
    fi
    pf_check_addons
    pf_check_sudo

    if [ "${PF_FAILED}" -gt 0 ]; then
        echo "Preflight failed: ${PF_FAILED} blocking issue(s), ${PF_WARNED} warning(s). Fix the [FAIL] items above."
        return 1
    fi
    local summary="Preflight passed"
    [ "${PF_WARNED}" -gt 0 ] && summary="${summary} with ${PF_WARNED} warning(s)"
    [ "${PF_PENDING}" -gt 0 ] && summary="${summary}; ${PF_PENDING} host change(s) still to apply (dev-setup does that)"
    echo "${summary}."
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    PF_SKIP_INOTIFY=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-inotify-check) PF_SKIP_INOTIFY=true; shift ;;
            -h|--help)
                echo "Usage: $0 [--skip-inotify-check]"
                echo ""
                echo "Checks the host for everything the dev environment needs before it"
                echo "creates anything: container tool, rootless podman permissions,"
                echo "inotify limits, registry host configuration, and sudo access."
                exit 0
                ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done
    preflight_run
fi
