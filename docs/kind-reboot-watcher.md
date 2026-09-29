# Kind reboot watcher

[`kind-reboot-watcher.sh`](../dev/kind-reboot-watcher.sh) makes a Kind worker
container reboot or be replaced after remediation. It is a helper for
development and end-to-end tests that need to exercise what happens after a
node is fenced or told to reboot.

The script supports these modes:

- **Watcher modes** (`snr`, `sbr`): long-running daemon that watches all
  worker nodes and restarts their containers when they remain NotReady and the
  expected remediation signal arrives.
- **Fence agent mode** (`far`): one-shot command that acts as a fence agent
  for FenceAgentsRemediation (FAR) on Kind. Receives standard fence agent
  arguments (`--action`, `--plug`) and calls the Docker REST API directly
  via the Unix socket, then exits.
- **MDR mode** (`mdr`): replaces a deleted fixture Machine with a fresh Kind
  worker. Requires `--once`; see [MDR setup](kind-mdr.md).

Kind nodes are containers sharing the host kernel. A reboot request from an
operator cannot reboot an individual Kind node the way it would reboot a real
machine. In SNR/SBR mode, the watcher observes NotReady nodes, waits for
the appropriate remediation signal, and restarts the corresponding Kind
node container. Restarting the container brings its kubelet back and makes the
Kubernetes node rejoin.

## What it watches

In `snr` and `sbr` modes, the watcher gets worker container names from
`kind get nodes --name <cluster-name>` and checks the Kubernetes `Ready`
condition. If it is not `True`, the watcher waits ten seconds and checks again.
Handling starts only if the node is still not Ready. It does not inspect the
kubelet service, so it can handle both stopped kubelets and network partitions.

The recheck gives transient NotReady states time to recover before a restart
is scheduled. The cluster is checked on each pass; if
the named cluster no longer exists, the watcher logs that fact and exits
successfully.

The main loop sleeps five seconds between scans, in addition to the ten-second
recheck for each newly unready worker. Once a worker qualifies,
the watcher marks it as being handled so it does not
start another restart job for the same node. Restart handling runs in a
background process, so different failed workers can wait for their signals in
parallel. The main process continues checking nodes and removes a node from
its in-progress list once its `Ready` condition is `True` again.

## Remediation modes

The mode determines what signal the watcher waits for before restarting a
node, or (for `far`) the action to take immediately. MDR waits for a fixture
Machine deletion request instead of Node health. The default is `snr`.

### SNR mode

For the NotReady worker, the watcher looks for a
`SelfNodeRemediation` object with a matching name across all namespaces. When
the worker first qualifies, it records the current object's UID as a baseline.
It then polls every five seconds until it sees an object with a **different
UID**. Waiting for a new object avoids acting on a stale remediation from an
earlier failure.

After the new object appears, the watcher restarts the worker container. SNR
mode does not recreate `/dev/watchdog` after restart.

### SBR mode

For the NotReady worker, the watcher looks for a
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

| Action | Docker API call | Exit 0 | Exit 1 |
| --- | --- | --- | --- |
| `reboot` | `POST /containers/{name}/restart` | HTTP 204; prints `Status: ON` | Any other HTTP status; prints `restart failed (HTTP ...)` |
| `on` | `POST /containers/{name}/start` | HTTP 204 or 304 (already started); prints `Status: ON` | Any other HTTP status; prints `start failed (HTTP ...)` |
| `off` | `POST /containers/{name}/stop` | HTTP 204 or 304 (already stopped); prints `Status: OFF` | Any other HTTP status; prints `stop failed (HTTP ...)` |
| `status` | `GET /containers/{name}/json` | HTTP 200 with `Running=true`; prints `Status: ON` | Non-200 HTTP status or a parsed `Running` value other than `true`; prints `Status: OFF` |

The `status` action is used by the FART (FenceAgentsRemediationTemplate) validation
controller, which calls `fence_kind --action status` for each node before marking
the template valid. It checks the output for `Status: ON` (case-insensitive).

`curl` is used instead of the `docker` CLI so the script can run inside
operator pods that have no container tool in `PATH`. `common.sh` is not
sourced in this mode (it would fail because `kubectl` and `docker`/`podman`
are absent). Unknown arguments, including `--ip` or `--disable-ssl`, are
rejected with an error and usage output.

The table assumes `curl` completes successfully. Transport failures propagate
curl's nonzero exit code (for example, `7` for a connection failure), without a
`Status:` message. If an HTTP 200 status response has no matching `Running`
field, the parsing pipeline exits with code `1`, also without a `Status:` message.
Missing `--action` or `--plug`, an invalid plug name, or an unsupported action
exits with code `1` and an error message. Plug names must match
`[a-zA-Z0-9][a-zA-Z0-9_.-]*`; validation happens before the API request.

**Socket path**: the host socket (Docker at `/var/run/docker.sock`, or a
Podman socket at a user-specific path) is bind-mounted into the Kind
control-plane node and then re-mounted into the FAR manager pod. The mount
point inside the pod is always `/var/run/docker.sock` regardless of the
host-side path, so `--unix-socket` in the FAR CR spec and in `fence_kind`
always use that fixed path. Set `CONTAINER_SOCKET_PATH` when running
[`dev/setup.sh`](../dev/setup.sh) to use a host socket other than
`/var/run/docker.sock`:

```bash
SETUP_DOCKER_SOCKET=true CONTAINER_SOCKET_PATH=/run/user/1000/podman/podman.sock ./dev/setup.sh
```

## Timeout and restart behavior

In SNR/SBR mode, the timeout is a per-node maximum wait for the remediation
signal. It starts after the Node remains NotReady through the ten-second
recheck. If the signal does not appear in time, the watcher logs a timeout
and restarts the node anyway. This fallback prevents the test from waiting
forever, but it means a container restart is **not proof** that remediation
completed successfully.

The timeout defaults to 300 seconds. The script passes it to its signal-wait
loop, which checks immediately and then sleeps in five-second increments.
After restarting a container, the background handler logs that it is waiting
for kubelet; the main watcher detects `Ready=True` on later scans.

Restart command error handling differs by mode:

- SNR mode runs the container restart as a required command. If it fails, that
  background handler exits due to strict Bash error handling; the watcher does
  not retry that restart. The main process keeps the node marked in progress
  until it sees `Ready=True`.
- SBR mode treats container restart and watchdog-device recreation as
  best-effort commands. It attempts device recreation even if the restart
  command failed.

MDR has separate five-minute deletion-request and fifteen-minute replacement
deadlines. A timeout fails the run; it never triggers forced recovery.
`--delay` does not configure MDR.

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

Stop a background SNR/SBR watcher with `make dev-reboot-watcher-stop`. That target
uses `pkill -f kind-reboot-watcher.sh`, so it stops matching watcher processes
on the local machine. When running the script directly in a terminal, use
Ctrl-C.

In SNR/SBR mode, `--once` exits after the first qualifying node is handled.
It waits for that node's remediation signal or timeout and for the restart handler to finish; it
does not wait for the node to become Ready again. In MDR mode, `--once` is
required and success means the replacement is Ready, networking is verified,
and the Machine annotation and worker label have been published. MDR replaces
the shell process with Python; stop its saved PID, as the generic stop target
only matches the shell script name.

## Options

| Option or environment variable | Default | Purpose |
| --- | --- | --- |
| `--name <cluster>` / `MEDIK8S_CLUSTER_NAME` | `medik8s-dev` | Kind cluster (`snr`, `sbr`, `mdr`). |
| `--delay <seconds>` / `MEDIK8S_REBOOT_DELAY` | `300` | Maximum remediation-signal wait per Node (`snr`, `sbr` only). |
| `--mode <snr\|sbr\|far\|mdr>` / `MEDIK8S_REBOOT_WATCHER_MODE` | `snr` | `snr`: wait for SelfNodeRemediation CR. `sbr`: wait for SBR FencingSucceeded. `far`: fence agent via Docker socket. `mdr`: simulate Machine deletion and fresh-worker replacement. |
| `--once` | off | Exit after one remediation; required for `mdr`. |
| `--action <reboot\|on\|off\|status>` | — | Action to execute (`far` mode only). |
| `--plug <container>` | — | Container name to act on (`far` mode only). |
| `--unix-socket <path>` | `/var/run/docker.sock` | Docker socket path for the REST API call (`far` mode only). |

SNR/SBR select `KUBECTL` and `CONTAINER_TOOL` through
[`common.sh`](../dev/common.sh). MDR defaults to `kubectl` and `podman` and
honors those environment overrides directly. `--help` prints usage and exits.

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
- `status` uses a separate GET request to `/containers/{plug}/json` and checks
  the `Running` field.
- Unknown arguments are rejected before any mode runs.

**Watcher modes** (`snr`, `sbr`; run after `common.sh` is sourced):

- `get_worker_nodes`: lists Kind node containers and selects names containing
  `worker`.
- `is_node_ready`: reads the node's Ready condition through Kubernetes and
  succeeds only when it is `True`.
- `get_snr_cr_uid` / `wait_for_remediation_cr`: find a fresh SNR object by UID.
- `get_sbr_cr_fencing_state` / `wait_for_fencing`: find a fresh SBR object
  with `FencingSucceeded=True`.
- The main loop rechecks NotReady nodes after ten seconds, prevents duplicate
  handling with `REBOOTING`, and clears that state when `Ready=True`.
- A background handler waits for the signal or timeout, restarts the
  container, and in SBR mode recreates the null watchdog device.

## MDR Machine replacement

MDR delegates to `kind_mdr.py watch` before `common.sh` is sourced. It discovers
fixture identities from Kubernetes and the container runtime, acts only on a
Machine's deletion timestamp, and provisions a new worker after deletion. It
uses no state directory or test-release gate and reports success or failure
through its exit status. See [Kind MDR simulation](kind-mdr.md) for setup,
ordering, and limits.
