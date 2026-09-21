# Shared raw block storage on Kind

Set `KIND_BLOCK_STORAGE=true` when using the shared `dev-setup` and
`dev-teardown` targets. Setup creates a disposable 64 MiB backing file, attaches
one host loop device (with `--direct-io=on`), and mounts that same device into two worker containers at
`/dev/medik8s-kind-block`. It installs a static `medik8s-kind-block` StorageClass
and a `hostPath` PV (`type: BlockDevice`) with `ReadWriteMany`. The device is unformatted;
the consuming application initializes its own on-disk data.

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
