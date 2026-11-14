#!/usr/bin/env bash
set -euo pipefail

MODE=${1:?Block mode is required}
TOOLS=/var/lib/medik8s/kind-block-tools
export PATH="$TOOLS/bin:$TOOLS/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
unset CONTAINER_HOST CONTAINER_CONNECTION DOCKER_HOST DOCKER_CONTEXT
[[ $(id -u) == 0 ]] || { echo "Run guest preparation as root." >&2; exit 1; }
mkdir -p "$TOOLS/bin"

packages=()
for pair in python3:python3 losetup:util-linux blockdev:util-linux modprobe:kmod curl:curl tar:tar gzip:gzip sha256sum:coreutils; do
    tool=${pair%%:*}
    command -v "$tool" >/dev/null || packages+=("${pair#*:}")
done
if [[ "$MODE" == per-node ]] && ! command -v dmsetup >/dev/null; then
    packages+=(device-mapper)
fi
if [[ ${#packages[@]} -gt 0 ]]; then
    if command -v rpm-ostree >/dev/null; then
        rpm-ostree install --apply-live --idempotent "${packages[@]}"
    elif command -v dnf >/dev/null; then
        dnf install -y "${packages[@]}"
    elif command -v apt-get >/dev/null; then
        for index in "${!packages[@]}"; do
            [[ ${packages[index]} != device-mapper ]] || packages[index]=dmsetup
        done
        apt-get update
        apt-get install -y "${packages[@]}"
    else
        echo "Install these tools in Podman Machine: ${packages[*]}" >&2
        exit 1
    fi
fi
for tool in python3 losetup blockdev modprobe curl tar gzip sha256sum podman; do
    command -v "$tool" >/dev/null || { echo "Guest tool remains unavailable: $tool" >&2; exit 1; }
done

case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Unsupported guest architecture: $(uname -m)" >&2; exit 1 ;;
esac
scratch=$(mktemp -d /tmp/medik8s-block-tools.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
download() {
    curl --fail --location --retry 3 --connect-timeout 15 --max-time 300 "$1" -o "$2"
}
check_digest() {
    [[ "$2" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid download checksum." >&2; exit 1; }
    printf '%s  %s\n' "$2" "$1" | sha256sum --check --status
}
if ! command -v kind >/dev/null; then
    url="https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-$arch"
    download "$url" "$scratch/kind"
    download "$url.sha256sum" "$scratch/kind.sha256"
    read -r digest _ < "$scratch/kind.sha256"
    check_digest "$scratch/kind" "$digest"
    install -m 0755 "$scratch/kind" "$TOOLS/bin/kind"
fi
if ! command -v kubectl >/dev/null; then
    url="https://dl.k8s.io/release/v1.35.0/bin/linux/$arch/kubectl"
    download "$url" "$scratch/kubectl"
    download "$url.sha256" "$scratch/kubectl.sha256"
    digest=$(cat "$scratch/kubectl.sha256")
    check_digest "$scratch/kubectl" "$digest"
    install -m 0755 "$scratch/kubectl" "$TOOLS/bin/kubectl"
fi
if ! command -v go >/dev/null; then
    name="go1.26.0.linux-$arch.tar.gz"
    download "https://go.dev/dl/?mode=json&include=all" "$scratch/go.json"
    digest=$(python3 - "$scratch/go.json" "$name" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    releases = json.load(stream)
print(next(item["sha256"] for release in releases for item in release["files"] if item["filename"] == sys.argv[2]))
PY
)
    download "https://go.dev/dl/$name" "$scratch/$name"
    check_digest "$scratch/$name" "$digest"
    tar -xzf "$scratch/$name" -C "$TOOLS"
fi

podman info --format json | python3 -c '
import json, sys
host = json.load(sys.stdin)["host"]
if host["security"]["rootless"] or host["serviceIsRemote"]:
    sys.exit("The guest requires a local rootful Podman engine.")
'
modprobe loop
[[ -c /dev/loop-control ]] || { echo "The guest kernel does not provide loop devices." >&2; exit 1; }
if [[ "$MODE" == per-node ]]; then
    modprobe dm_mod
    targets=$(dmsetup targets)
    for target in linear error; do
        grep -qE "^[[:space:]]*${target}[[:space:]]" <<< "$targets" || {
            echo "The guest kernel lacks the device-mapper $target target." >&2; exit 1;
        }
    done
fi
