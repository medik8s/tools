# Kind reboot watcher

[`kind-reboot-watcher.sh`](../dev/kind-reboot-watcher.sh) makes a Kind worker
container act like a machine that reboots after remediation. It is a helper for
development and end-to-end tests that need to exercise what happens after a
node is fenced or told to reboot.

The script has two distinct personalities depending on `--mode`:

- **Watcher modes** (`snr`, `sbr`): long-running daemon that watches all
  worker nodes and restarts their containers when kubelet stops and the
  expected remediation signal arrives.
- **Fence agent mode** (`far`): one-shot command that acts as a fence agent
  for FenceAgentsRemediation (FAR) on Kind. Receives standard fence agent
  arguments (`--action`, `--plug`) and calls the Docker REST API directly
  via the Unix socket, then exits.

Kind nodes are containers sharing the host kernel. A reboot request from an
operator cannot reboot an individual Kind node the way it would reboot a real
machine. The watcher fills that gap by observing stopped kubelets, waiting for
the appropriate remediation signal, and restarting the corresponding Kind
node container. Restarting the container brings its kubelet back and makes the
Kubernetes node rejoin.

## What it watches

The watcher gets worker container names from `kind get nodes --name
<cluster-name>` and keeps checking them. A worker is considered ready for
handling when **both** of these conditions are true:

1. Kubernetes does not report that node's `Ready` condition as `True`.
2. `systemctl is-active kubelet` inside the Kind node container says kubelet
   is not active.

This combination avoids treating a temporarily NotReady node with a still
running kubelet as a reboot request. The cluster is checked on each pass; if
the named cluster no longer exists, the watcher logs that fact and exits
successfully.

The main worker scan repeats every five seconds. Once a worker meets the
stopped-kubelet condition, the watcher marks it as being handled so it does not
start another restart job for the same node. Restart handling runs in a
background process, so different failed workers can wait for their signals in
parallel. The main process continues checking nodes and removes a node from
its in-progress list once its kubelet is active again.

## Remediation modes

The mode determines what signal the watcher waits for before restarting a
node, or (for `far`) the action to take immediately. The default is `snr`.

### SNR mode

For the stopped worker, the watcher looks for a
`SelfNodeRemediation` object with a matching name across all namespaces. When
the worker first qualifies, it records the current object's UID as a baseline.
It then polls every five seconds until it sees an object with a **different
UID**. Waiting for a new object avoids acting on a stale remediation from an
earlier failure.

After the new object appears, the watcher restarts the worker container. SNR
mode does not recreate `/dev/watchdog` after restart.

### SBR mode

For the stopped worker, the watcher looks for a
`StorageBasedRemediation` object with a matching name across all namespaces.
It records the current object's UID as a baseline and polls every five seconds
for a new object whose `FencingSucceeded` condition has status `True`. Both
parts must match: an old object that already says fencing succeeded is not
enough.

Waiting for fencing to succeed gives the victim's heartbeat time to age past
the fencing threshold before the node agent resumes. Restarting too early
could let the agent resume heartbeating before fencing is confirmed.

After the signal or timeout, the watcher restarts the worker container, then
attempts to recreate `/dev/watchdog` inside it as a null-backed character
device (major 1, minor 3). Container restart loses that per-node device, and
the recreation lets multiple Kind node agents open their own watchdog device
after they come back. Device recreation is best effort; errors are suppressed.
The cluster must have been prepared for this setup, typically with
`SETUP_NULL_DEVICE_WATCHDOG=true make dev-setup`.

### FAR mode

FAR mode is a one-shot fence agent, not a watcher. It is designed to be
installed inside the FAR operator image and invoked by the FAR controller as
a replacement for `fence_docker` on Kind clusters.

When `--mode far` is set, the script reads `--action` and `--plug`, then
calls the Docker REST API via `--unix-socket` (default:
`/var/run/docker.sock`) using `curl`. It exits immediately after the call
succeeds or fails:

| Action | Docker API call | Success output |
| --- | --- | --- |
| `reboot` | `POST /containers/{name}/restart` | exit 0 |
| `on` | `POST /containers/{name}/start` | exit 0 |
| `off` | `POST /containers/{name}/stop` | exit 0 |
| `status` | `GET /containers/{name}/json` | `Status: ON` + exit 0 if running; `Status: OFF` + exit 1 otherwise |

The `status` action is used by the FART (FenceAgentsRemediationTemplate) validation
controller, which calls `fence_kind --action status` for each node before marking
the template valid. It checks the output for `Status: ON` (case-insensitive).

`curl` is used instead of the `docker` CLI so the script can run inside
operator pods that have no container tool in `PATH`. `common.sh` is not
sourced in this mode (it would fail because `kubectl` and `docker`/`podman`
are absent). Any extra arguments passed by the FAR controller (for example
`--ip` or `--disable-ssl`) are silently ignored.

Exit code is `0` on HTTP 204 (success) and `1` on any other response.

**Socket path**: the host socket (Docker at `/var/run/docker.sock`, or a
Podman socket at a user-specific path) is bind-mounted into the Kind
control-plane node and then re-mounted into the FAR manager pod. The mount
point inside the pod is always `/var/run/docker.sock` regardless of the
host-side path, so `--unix-socket` in the FAR CR spec and in `fence_kind`
always use that fixed path. The `local-run.sh` script detects the correct
host socket automatically and passes it to the Kind cluster setup. If
auto-detection picks the wrong path, set `CONTAINER_SOCKET_PATH` to override
it:

```bash
CONTAINER_SOCKET_PATH=/run/user/1000/podman/podman.sock ./hack/local-run.sh
```

## Timeout and restart behavior

The timeout is a per-node maximum wait for the mode's remediation signal. It
starts when the watcher detects that node's kubelet is stopped and the node is
not Ready. If the signal does not appear in time, the watcher logs a timeout
and restarts the node anyway. This fallback prevents the test from waiting
forever, but it means a container restart is **not proof** that remediation
completed successfully.

The timeout defaults to 300 seconds. The script passes it to its signal-wait
loop, which checks immediately and then sleeps in five-second increments.
After restarting a container, the background handler logs that it is waiting
for kubelet; the main watcher detects kubelet recovery on later scans.

Restart command error handling differs by mode:

- SNR mode runs the container restart as a required command. If it fails, that
  background handler exits due to strict Bash error handling; the watcher does
  not retry that restart. The main process keeps the node marked in progress
  until it sees kubelet active.
- SBR mode treats container restart and watchdog-device recreation as
  best-effort commands. It attempts device recreation even if the restart
  command failed.

## Start and stop

The watcher runs in the foreground when invoked directly. Start it in the
background before simulating a failure:

```bash
# Default cluster name, SNR mode, 300-second timeout
make dev-reboot-watcher

# In another terminal, trigger the failure and inspect the remediation flow
make dev-simulate-failure
kubectl get nodes -w
kubectl get selfnoderemediation -A -w
```

For SBR, choose SBR mode when starting the watcher:

```bash
MEDIK8S_REBOOT_WATCHER_MODE=sbr make dev-reboot-watcher
```

You can run the script directly to set all options explicitly:

```bash
./dev/kind-reboot-watcher.sh --name medik8s-dev --mode sbr --delay 420
```

For FAR, the script is invoked as a one-shot fence agent (typically by the FAR
controller inside the operator pod, not by hand):

```bash
./dev/kind-reboot-watcher.sh --mode far --action reboot --plug medik8s-dev-worker \
    --unix-socket /var/run/docker.sock
```

Stop a background watcher with `make dev-reboot-watcher-stop`. That target
uses `pkill -f kind-reboot-watcher.sh`, so it stops matching watcher processes
on the local machine. When running the script directly in a terminal, use
Ctrl-C.

`--once` exits after the first qualifying node is handled. It waits for that
node's remediation signal or timeout and for the restart handler to finish; it
does not wait for the node to become Ready again.

## Options

| Option or environment variable | Default | Purpose |
| --- | --- | --- |
| `--name <cluster>` / `MEDIK8S_CLUSTER_NAME` | `medik8s-dev` | Kind cluster to watch (watcher modes only). |
| `--delay <seconds>` / `MEDIK8S_REBOOT_DELAY` | `300` | Maximum seconds to wait for a remediation signal per detected node (watcher modes only). |
| `--mode <snr\|sbr\|far>` / `MEDIK8S_REBOOT_WATCHER_MODE` | `snr` | `snr`: wait for SelfNodeRemediation CR. `sbr`: wait for SBR FencingSucceeded. `far`: one-shot fence agent via Docker socket. |
| `--once` | off | Exit after handling the first qualifying node (watcher modes only). |
| `--action <reboot\|on\|off>` | — | Action to execute (`far` mode only). |
| `--plug <container>` | — | Container name to act on (`far` mode only). |
| `--unix-socket <path>` | `/var/run/docker.sock` | Docker socket path for the REST API call (`far` mode only). |

The script also uses `KUBECTL` and `CONTAINER_TOOL` if set; otherwise it
inherits the command selection from [`common.sh`](../dev/common.sh). `--help` prints
the command usage and exits.

## What this does and does not simulate

In watcher modes (`snr`, `sbr`), the script restarts the **Kind node
container**. That stops and starts the container and its kubelet, which
approximates the node restart/rejoin portion of a real remediation flow. It
does not restart the host, issue a real hardware reboot, validate that physical
fencing worked, or provide a general-purpose watchdog service. It depends on
Kind, access to the selected node containers, and Kubernetes API access. It is
not the watcher to use for an external OpenShift cluster.

For SNR, the observed CR is evidence that remediation was requested; the
watcher does not inspect the remediation CR's completion status before
restarting. For SBR, it specifically waits for `FencingSucceeded=True`. In
both modes, the timeout fallback can restart the container without seeing the
expected signal.

In fence agent mode (`far`), the script acts as a thin replacement for
`fence_docker` on Kind. It does not watch nodes or wait for signals; it simply
calls the Docker REST API for the named container and exits. No separate
reboot watcher is needed alongside FAR because FAR itself drives the fence
action directly.

## Implementation map

**FAR fence agent mode** (runs before `common.sh` is sourced; exits immediately):

- Arg parsing runs first so `--mode far` is detected without requiring
  `kubectl` or a container tool in `PATH`.
- `docker_api`: issues a `curl --unix-socket` POST to the Docker REST API and
  returns the HTTP status code.
- Actions `reboot`, `on`, `off` map to `/containers/{plug}/restart|start|stop`.
- Unknown arguments are silently ignored so the FAR controller can pass its
  standard fence agent parameters without modification.

**Watcher modes** (`snr`, `sbr`; run after `common.sh` is sourced):

- `get_worker_nodes`: lists Kind node containers and selects names containing
  `worker`.
- `is_node_not_ready`: reads the node's Ready condition through Kubernetes;
  any value other than `True` is treated as not Ready.
- `is_kubelet_running`: checks the kubelet service inside the node container.
- `get_snr_cr_uid` / `wait_for_remediation_cr`: find a fresh SNR object by UID.
- `get_sbr_cr_fencing_state` / `wait_for_fencing`: find a fresh SBR object
  with `FencingSucceeded=True`.
- The main loop detects stopped kubelets, prevents duplicate handling, and
  watches for kubelet recovery.
- A background handler waits for the signal or timeout, restarts the
  container, and in SBR mode recreates the null watchdog device.
