#!/bin/bash
# Container tool discovery for the medik8s dev environment.
#
# Sourced by common.sh and executed by dev.mk. Discovery only accepts a tool
# whose daemon actually answers: a docker CLI with a stopped daemon, or a
# socket the current user cannot reach, is skipped here instead of failing
# later inside kind with a cryptic "failed to get docker info" error.
#
# Standalone usage:
#   ./container-tool.sh detect        # print the tool to use (exit 1 if none)
#   ./container-tool.sh check <tool>  # exit 0 when <tool> is usable
#   ./container-tool.sh hint <tool>   # explain why <tool> is not usable

# Installed and responding?
container_tool_works() {
    [[ -n "$1" ]] && command -v "$1" &>/dev/null && "$1" info &>/dev/null
}

# One-line explanation for an unusable tool. Keep parentheses balanced and the
# text on a single line: dev.mk embeds this in $(info)/$(warning).
container_tool_hint() {
    local tool="$1"
    if [[ -z "${tool}" ]]; then
        echo "no container tool is set."
        return
    fi
    if ! command -v "${tool}" &>/dev/null; then
        echo "${tool} is not installed."
        return
    fi
    case "${tool}" in
        docker)
            echo "'docker info' failed: the daemon is not running, or /var/run/docker.sock is not accessible to $(id -un). Try 'sudo systemctl start docker' or add yourself to the 'docker' group."
            ;;
        podman)
            echo "'podman info' failed: the podman service is not usable. Try 'podman system service --time=0' or check 'podman info' output."
            ;;
        *)
            echo "'${tool} info' failed: the container runtime is not usable."
            ;;
    esac
}

# Print the tool to use, or nothing (exit 1) when none is usable.
# Preference: a working tool that already owns the Kind cluster's containers,
# then podman, then docker.
detect_container_tool() {
    local cluster="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}" tool
    local usable=()

    for tool in podman docker; do
        container_tool_works "${tool}" && usable+=("${tool}")
    done

    [[ ${#usable[@]} -eq 0 ]] && return 1

    if [[ ${#usable[@]} -gt 1 ]]; then
        for tool in "${usable[@]}"; do
            if "${tool}" container inspect "${cluster}-control-plane" &>/dev/null; then
                echo "${tool}"
                return 0
            fi
        done
    fi

    echo "${usable[0]}"
}

# Report every candidate when nothing is usable.
container_tool_error() {
    local tool
    echo "Error: no usable container tool found; docker or podman is required." >&2
    for tool in podman docker; do
        echo "  ${tool}: $(container_tool_hint "${tool}")" >&2
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-detect}" in
        detect) detect_container_tool ;;
        check) container_tool_works "${2:-}" ;;
        hint) container_tool_hint "${2:-}" ;;
        *)
            echo "Usage: $0 [detect|check <tool>|hint <tool>]" >&2
            exit 2
            ;;
    esac
fi
