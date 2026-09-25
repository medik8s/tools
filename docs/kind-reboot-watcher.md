# Kind reboot watcher

[`kind-reboot-watcher.sh`](../dev/kind-reboot-watcher.sh) makes a Kind worker
container act like a machine that reboots after remediation. It is a helper for
development and end-to-end tests that need to exercise what happens after a
node is fenced or told to reboot.

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
node. The default is `snr`.

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

### FAR with `fence_docker`

FAR uses a different Kind flow. Its `fence_docker` agent power-cycles worker
Kind containers through the container engine socket; the reboot watcher does
not wait for FAR remediation objects and should not be started for FAR fencing
tests. The watcher supports only `snr` and `sbr` modes.

Create the cluster with the host socket mounted into its control-plane node
before deploying FAR:

```bash
SETUP_DOCKER_SOCKET=true make dev-setup
```

This option must be set when the cluster is created because Kind cannot add
the socket mount to an existing node. To enable it on an existing cluster,
recreate the cluster first:

```bash
make dev-teardown
SETUP_DOCKER_SOCKET=true make dev-setup
```

For Podman or a non-default socket location, set `CONTAINER_SOCKET_PATH` to
the host socket path as well. Setup mounts that path at
`/var/run/docker.sock` inside the control-plane node and checks that the
socket is available there. The FAR manager pod uses this socket to control
worker containers, so deploy FAR with an e2e image that includes
`fence_docker`; the shipped operator image does not include that agent.

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
| `--name <cluster>` / `MEDIK8S_CLUSTER_NAME` | `medik8s-dev` | Kind cluster to watch. |
| `--delay <seconds>` / `MEDIK8S_REBOOT_DELAY` | `300` | Maximum seconds to wait for a remediation signal per detected node. |
| `--mode <snr-or-sbr>` / `MEDIK8S_REBOOT_WATCHER_MODE` | `snr` | Select the SNR CR or SBR fencing condition to wait for. |
| `--once` | off | Exit after handling the first qualifying node. |

The script also uses `KUBECTL` and `CONTAINER_TOOL` if set; otherwise it
inherits the command selection from [`common.sh`](../dev/common.sh). `--help` prints
the command usage and exits.

## What this does and does not simulate

The watcher restarts the **Kind node container**. That stops and starts the
container and its kubelet, which approximates the node restart/rejoin portion
of a real remediation flow. It does not restart the host, issue a real hardware
reboot, validate that physical fencing worked, or provide a general-purpose
watchdog service. It depends on Kind, access to the selected node containers,
and Kubernetes API access. It is not the watcher to use for an external
OpenShift cluster.

For SNR, the observed CR is evidence that remediation was requested; the
watcher does not inspect the remediation CR's completion status before
restarting. For SBR, it specifically waits for `FencingSucceeded=True`. In
both modes, the timeout fallback can restart the container without seeing the
expected signal.

## Implementation map

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
