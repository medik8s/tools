# Shared raw block storage on Kind

Set `KIND_BLOCK_STORAGE=true` when using the shared `dev-setup` and
`dev-teardown` targets. Setup creates a disposable 64 MiB backing file, attaches
one host loop device (with `--direct-io=on`), and mounts that same device into two worker containers at
`/dev/medik8s-kind-block`. It installs a static `medik8s-kind-block` StorageClass
and a local PV with `ReadWriteMany`. The device has no filesystem.
The consuming application initializes its data.

This is a test fixture for containers sharing one Linux kernel. It does not
provide distributed storage or validate a production CSI driver's behavior.
Only one PVC can bind to the PV at a time. Start a fresh environment to reset
the device and PV between test runs.

## Usage

On Linux, prerequisites are Kind, kubectl, Go, Python 3, and util-linux (`losetup`).
Device operations require root or passwordless sudo.
Supported engines are local rootful Docker and local Podman. Rootless Podman is supported through device ownership changes.
On macOS, use the Podman Machine wrapper below.
Docker Desktop, Windows, remote engines outside that wrapper, and rootless Docker are unsupported.

From an operator repository whose Makefile includes `dev/dev.mk`:

```bash
export CONTAINER_TOOL=docker
export MEDIK8S_CLUSTER_NAME=block-dev
export KIND_BLOCK_STORAGE=true
export KIND_BLOCK_STATE_DIR="$PWD/dist/block-dev"
export KUBECONFIG="$KIND_BLOCK_STATE_DIR/kubeconfig"
export SKIP_REGISTRY=true  # optional, when loading images with kind load

sudo modprobe loop
make dev-setup
kubectl get pv,sc
# Build, load, and deploy your application and a Block PVC.
make dev-teardown
```

## Private Block volumes

Set `KIND_BLOCK_MODE=per-node` for one private device per worker.
`KIND_BLOCK_STORAGE=true` still enables the fixture.
The default worker count is three. `KIND_BLOCK_WORKERS` accepts integers of at least three.
`KIND_HA=true` adds three control planes and preserves the requested worker count.
Shared mode rejects `KIND_BLOCK_WORKERS`.

Private mode executes inside Linux with a local rootful Docker or Podman engine.
It also requires `python3`, `truncate`, `losetup`, `blockdev`, and `dmsetup`.
The kernel must provide the device-mapper `linear` and `error` targets.
Device commands require root or passwordless sudo.
On macOS, the wrapper executes these commands inside Podman Machine.
Private mode rejects remote engines, rootless engines, and `SKIP_KIND=true`.

Setup also creates missing `/dev/loop*` device nodes inside each worker.
Kubelet holds a loop-device reference for every raw Block volume it maps,
and hosts that create those nodes only for attached loops would otherwise
leave consumer Pods in `ContainerCreating`.

Each worker receives a separate 64 MiB image, direct-I/O loop device, and device-mapper mapping.
Only its assigned worker receives that mapping at `/dev/medik8s-kind-block`.
Control planes receive no fixture devices.
Privileged containers still share the host kernel. These mappings do not provide a security boundary.

The `medik8s-kind-block-per-node` StorageClass uses `kubernetes.io/no-provisioner` and `WaitForFirstConsumer`.
Each static PV uses `ReadWriteOnce`, `Block`, `Retain`, and the exact worker hostname.

```bash
export CONTAINER_TOOL=docker
export MEDIK8S_CLUSTER_NAME=private-block-dev
export KIND_BLOCK_STORAGE=true
export KIND_BLOCK_MODE=per-node
export KIND_BLOCK_WORKERS=3
export KIND_BLOCK_STATE_DIR="$PWD/dist/private-block-dev"
export KUBECONFIG="$KIND_BLOCK_STATE_DIR/kubeconfig"
export SKIP_REGISTRY=true
sudo modprobe loop
sudo modprobe dm_mod
make dev-setup
kubectl get pv,sc
```

Use a generic ephemeral volume for each test Pod.
Request `10Mi`, `ReadWriteOnce`, `Block`, and the private StorageClass.
Set `medik8s.io/kind-block-fixture` on the Pod and claim template to the identifier in `fixture.json`.
Use required node affinity with the assigned worker's exact `kubernetes.io/hostname` value.
Use `volumeDevices` in the container.
Omit `spec.nodeName` and `volumeName` when creating the Pod.
The scheduler must bind the claim.
The [smoke test](tests/kind_block_per_node_smoke.py) contains a complete Pod example.

## Replacement claims

One PV supports one active consumer per worker.
A retained PV keeps its old claim reference after claim deletion.
The replacement Pod remains Pending until an explicit reclaim action releases that PV.
This fixture does not provide dynamic provisioning.
Production SBR still requires a suitable dynamic CSI provisioner.

Keep the same environment for these commands.

1. Record the original consumer before deletion.

   ```bash
   make dev-kind-block-reclaim NODE=private-block-dev-worker ACTION=prepare NAMESPACE=tests POD=original
   ```

2. Delete the original Pod through the API.

   ```bash
   kubectl delete pod original -n tests
   ```

3. Create the replacement Pod with a generic ephemeral volume.

   ```bash
   kubectl create -f replacement.yaml
   ```

4. Reclaim the PV for the recorded replacement.

   ```bash
   make dev-kind-block-reclaim NODE=private-block-dev-worker ACTION=reclaim NAMESPACE=tests POD=replacement
   ```

Each action has a total deadline of 120 seconds.
The helper checks Pod, PVC, PV, Node, container, and device identities.
It waits for the original Pod and claim to disappear.
It checks remaining containers, kubelet mappings, and the device open count before changing the PV.
The JSON Patch tests the PV UID, resource version, and old claim reference.
Failed responses leave the operation record available for a retry.
Repeat the same reclaim command after an error.
The helper resolves an uncertain patch through live reads before another mutation.
It never restores an old claim reference or removes protection finalizers.

The helper preserves `/var/lib/medik8s/state` on each node.
Probe data does not represent the SBR journal.
The smoke test checks a host sentinel across Pod and claim replacement.

## Private device faults and cleanup

Use one recorded worker for each fault command.

```bash
make dev-kind-block-fault NODE=private-block-dev-worker ACTION=error
make dev-kind-block-fault NODE=private-block-dev-worker ACTION=restore
make dev-kind-block-fault NODE=private-block-dev-worker ACTION=hang
make dev-kind-block-fault NODE=private-block-dev-worker ACTION=restore
make dev-teardown
python3 ../tools/dev/kind_block_per_node.py verify-clean
```

`error` installs the device-mapper error target.
`hang` suspends the mapping without flushing pending I/O.
`restore` reinstalls the saved linear table and resumes the mapping.
Each fault action has a ten-second deadline.
Restore a suspended mapping before waiting for a blocked I/O process.
A process timeout does not cancel blocked kernel I/O.

Setup, reclaim, faults, and teardown hold exclusive fixture locks.
A second directory cannot claim the same cluster name and engine endpoint.
Lock records include the owner process. A stale or uncertain lock requires inspection.
The helper never removes a lock because of its age.

Setup failure triggers cleanup.
Teardown restores device mappings before removing Kind nodes.
It removes mappings and loops only after a successful query proves all node containers are absent.
It removes each image only after successful queries prove its mapping and loop are absent.
Failed cleanup preserves the affected image and records for a retry.
Repeat `make dev-teardown` with the same settings.
Keep `fixture.json` and reclaim records for inspection.
Do not delete state files to bypass a failed cleanup check.
The helper also checks each image's recorded device and inode numbers.
An interruption before this record exists can leave a file that requires manual inspection.
The helper preserves such files instead of inferring ownership from their names.

The private workflow checks real binding, direct I/O, faults, replacement claims, and cleanup on Linux.
Mocked tests check command sequences and failure handling on macOS and Linux.
Neither test qualifies SBR reboot evidence, hardware watchdogs, CSI behavior, or KubeVirt isolation.

## macOS with Podman Machine

Both Block modes can execute inside an existing rootful Podman Machine.
The macOS host needs Podman, Python 3, and SSH.
Install kubectl on macOS to inspect workloads from the host.
The wrapper starts a stopped machine. It does not create, resize, replace, or reboot the machine.
Set `KIND_BLOCK_MACHINE` when more than one machine exists.

The wrapper installs missing Linux tools inside the VM.
It downloads Kind v0.33.0, kubectl v1.35.0, and Go 1.26.0 when those tools are absent.
It checks each download against its published SHA256 checksum.
Missing system tools use the guest package manager. Fedora CoreOS uses `rpm-ostree --apply-live`.
Preparation stops if the tools or kernel features remain unavailable.
No macOS `modprobe` command is required.

The wrapper also prepares loop device nodes inside its Kind workers.
Kubelet uses additional loop devices when it maps raw Block volumes.
The prepared range includes 256 numbers above the highest loop number present at setup.
New loop numbers outside that range require fixture recreation.
Recreate the fixture after a worker container restarts, because the restart can remove these device nodes.

Run these commands from the `tools` repository:

```bash
export CONTAINER_TOOL=podman
export KIND_BLOCK_MACHINE=medik8s
export MEDIK8S_CLUSTER_NAME=mac-block-dev
export KIND_BLOCK_STORAGE=true
export KIND_BLOCK_MODE=shared
unset KIND_BLOCK_WORKERS
export KIND_BLOCK_STATE_DIR="$PWD/dist/mac-block-dev"
export KUBECONFIG="$KIND_BLOCK_STATE_DIR/kubeconfig"
export SKIP_REGISTRY=true

bash dev/setup.sh --skip-olm
kubectl get pv,sc
```

For private devices, use a separate cluster and state directory:

```bash
export MEDIK8S_CLUSTER_NAME=mac-private-block-dev
export KIND_BLOCK_MODE=per-node
export KIND_BLOCK_WORKERS=3
export KIND_BLOCK_STATE_DIR="$PWD/dist/mac-private-block-dev"
export KUBECONFIG="$KIND_BLOCK_STATE_DIR/kubeconfig"

bash dev/setup.sh --skip-olm
python3 dev/kind_block_machine.py exec -- python3 dev/tests/kind_block_per_node_smoke.py
```

Setup, teardown, and private fault and reclaim commands select the wrapper automatically on macOS.
Keep the same environment for each command.
`SKIP_REGISTRY=true` applies inside the VM. The wrapper does not configure an operator image registry.

Backing files and device records stay inside the VM.
The local `machine.json` records the machine identity and guest directory identifier.
The local kubeconfig uses a loopback SSH tunnel to the guest API server.
If the tunnel stops, restore it with:

```bash
python3 dev/kind_block_machine.py connect
```

Execute commands that need guest device records through `exec --`.
The wrapper sets the guest state directory and kubeconfig for those commands.
Guest smoke artifacts remain under the recorded guest directory.

To remove the fixture:

```bash
make dev-teardown
python3 dev/kind_block_machine.py verify-clean
```

Teardown removes the fixture cluster and devices before it stops the API tunnel.
It preserves records after a cleanup error so that the same command can retry.
It refuses to use a replacement VM with the same name.
It does not remove guest tools, other clusters, or the Podman Machine.
