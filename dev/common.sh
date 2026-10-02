#!/bin/bash
# Shared helpers for medik8s dev scripts.
# Source this from other scripts: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Several scripts source this file directly and through each other; detection
# (which probes the container tool) must run only once per process.
[[ -n "${MEDIK8S_COMMON_SOURCED:-}" ]] && return 0
MEDIK8S_COMMON_SOURCED=1

# shellcheck source=container-tool.sh
source "$(dirname "${BASH_SOURCE[0]}")/container-tool.sh"

# Detect kubectl or oc
detect_kubectl() {
    if command -v kubectl &>/dev/null; then
        echo kubectl
    elif command -v oc &>/dev/null; then
        echo oc
    else
        echo "Error: kubectl or oc is required but neither is installed." >&2
        echo "Install kubectl from: https://kubernetes.io/docs/tasks/tools/" >&2
        exit 1
    fi
}

KUBECTL="${KUBECTL:-$(detect_kubectl)}"

# A CONTAINER_TOOL coming from the caller is that caller's explicit choice, so
# honor it; only say something when it cannot work. Otherwise discover a tool
# that actually responds (see container-tool.sh).
if [[ -n "${CONTAINER_TOOL:-}" ]]; then
    container_tool_works "${CONTAINER_TOOL}" || \
        echo "Warning: CONTAINER_TOOL=${CONTAINER_TOOL} but $(container_tool_hint "${CONTAINER_TOOL}")" >&2
else
    CONTAINER_TOOL="$(detect_container_tool)" || { container_tool_error; exit 1; }
fi

# True when kind_sudo has a realistic chance of succeeding: root, passwordless
# sudo, or an interactive shell where sudo may prompt. CI and other
# non-interactive runs only count passwordless sudo, since kind_sudo uses -n there.
can_sudo() {
    [[ $(id -u) == 0 ]] && return 0
    command -v sudo &>/dev/null || return 1
    sudo -n true 2>/dev/null && return 0
    [[ "${CI:-false}" != "true" && -t 0 ]]
}

# Addresses the host resolves a name to, for messages: space separated, capped
# at three, empty when unresolved.
registry_resolved_addresses() {
    command -v getent &>/dev/null || return 0
    local all count
    all="$(getent hosts "$1" 2>/dev/null | awk '{print $1}' | sort -u)"
    [[ -n "${all}" ]] || return 0
    count="$(printf '%s\n' "${all}" | wc -l)"
    if [[ "${count}" -gt 3 ]]; then
        printf '%s and %d more' "$(printf '%s\n' "${all}" | head -3 | tr '\n' ' ' | sed 's/ $//')" "$((count - 3))"
    else
        printf '%s\n' "${all}" | tr '\n' ' ' | sed 's/ $//'
    fi
}

# The local registry is published on 127.0.0.1 only, so its hostname has to
# resolve to loopback and nothing else — a stray DNS answer would silently send
# pushes to another host.
registry_resolves_locally() {
    local addresses address
    addresses="$(registry_resolved_addresses "$1")"
    [[ -n "${addresses}" ]] || return 1
    for address in ${addresses}; do
        [[ "${address}" == 127.* || "${address}" == "::1" ]] || return 1
    done
    return 0
}

# Can docker push to <host:port> over HTTP? Ask the daemon for its effective
# configuration instead of reading daemon.json, which may be unparsed, unapplied
# (no restart), or overridden by --insecure-registry flags.
docker_registry_is_insecure() {
    local entry="$1"
    [[ "$(docker info --format "{{with index .RegistryConfig.IndexConfigs \"${entry}\"}}{{.Secure}}{{end}}" 2>/dev/null)" == false ]] && return 0
    # Loopback registries are insecure by default via the 127.0.0.0/8 CIDR.
    registry_resolves_locally "${entry%%:*}"
}

kind_sudo() {
    if [[ $(id -u) == 0 ]]; then
        "$@"
    elif [[ "${CI:-false}" == "true" || ! -t 0 ]]; then
        # CI or non-interactive environment: fail fast if password is required
        sudo -n "$@"
    else
        # Local interactive environment: allow password prompts
        sudo "$@"
    fi
}
