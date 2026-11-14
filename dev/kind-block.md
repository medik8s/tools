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

Prerequisites: native Linux, Kind, kubectl, Go, util-linux (`losetup`), and either root or passwordless sudo for loop-device operations. 
Supported container engines: local rootful Docker, or local Podman. 
Docker Desktop, Podman Machine (macOS/Windows), remote engines, and rootless Docker are unsupported. (Rootless Podman is supported via dynamic device ownership).

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

Private mode requires native Linux and a local rootful Docker or Podman engine.
It also requires `python3`, `truncate`, `losetup`, `blockdev`, and `dmsetup`.
The kernel must provide the device-mapper `linear` and `error` targets.
Device commands require root or passwordless sudo.
Use a native Linux environment when the development host runs macOS.
Private mode rejects remote engines, rootless engines, and `SKIP_KIND=true`.

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
sudo modprobe loop dm_mod
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
