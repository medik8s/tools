#!/usr/bin/env bash
# setup-null-device-watchdog.sh — Provide a per-node /dev/watchdog on every Kind node.
#
# Why not the real softdog device: Kind runs every node-container on ONE shared
# host kernel with ONE softdog miscdevice (major 10, minor 130). Watchdog char
# devices are single-open, so once one node's agent opens /dev/watchdog every
# other node gets EBUSY ("device or resource busy") and its agent CrashLoops.
# Operators like SBR need EVERY node's agent to hold its OWN watchdog concurrently,
# so the real softdog can never satisfy more than one node in Kind.
#
# What this does instead: point each node's /dev/watchdog at the null driver
# (major 1, minor 3). The null device is a CHARACTER device (readiness probes that
# run `test -c /dev/watchdog` pass) and is not single-open, so every node opens
# its own independently. The sysfs watchdog timeout attribute is still provided by
# softdog (loaded with soft_noboot=1 purely for this purpose), so agents that read
# /sys/class/watchdog/watchdog0/timeout get a valid timeout without opening the
# softdog char device.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"

echo "=== Ensuring per-node /dev/watchdog (null-backed char device) on each Kind node ==="
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  "${CONTAINER_TOOL}" exec "${node}" sh -c '
    # softdog only provides the sysfs timeout attribute; its char device is never opened.
    grep -q softdog /proc/modules 2>/dev/null || modprobe softdog soft_noboot=1
    # Replace any existing node (it may be the shared softdog char device) with a
    # per-node null-backed CHAR device so concurrent opens across nodes never hit
    # EBUSY and the readiness probe test -c /dev/watchdog passes.
    rm -f /dev/watchdog
    mknod /dev/watchdog c 1 3
    ls -l /dev/watchdog
    echo "watchdog0 timeout: $(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null || echo unavailable)"'
done
echo "=== Null-device watchdog setup complete ==="
