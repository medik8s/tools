# MDR Machine lifecycle simulation

`dev/kind_mdr.py` simulates one Machine replacement on a disposable Podman or
Docker Kind cluster. The MDR repository's `hack/kind-e2e.sh` owns cluster setup,
operator deployment, E2E execution, and teardown. SNR/SBR reboot and FAR behavior
remain separate.

Prepare one Ready control plane and two Ready workers, using MDR's
`config/kind-e2e/cluster.yaml` with `KIND_CONFIG` when invoking `dev/setup.sh`:

```bash
python3 dev/kind_mdr.py prepare --name mdr-kind-e2e --state-dir /tmp/mdr-run \
  --crd-dir ../machine-deletion-remediation/vendor/github.com/openshift/api/machine/v1beta1/zz_generated.crd-manifests
```

Preparation installs the vendored Machine/MachineSet CRDs, creates two linked
Machines in `kind-mdr-machines`, and records their identities in `fixture.json`.
It does not reserve or stop a container. Use the cluster's isolated `KUBECONFIG`
and `CONTAINER_TOOL=podman` (the default).

```bash
dev/kind-reboot-watcher.sh --mode mdr --once --name mdr-kind-e2e --state-dir /tmp/mdr-run
```

The `ready` file signals fixture validation. A fixture Machine's deletion
timestamp triggers removal of its recorded container, UID-guarded Node deletion,
and removal of only `medik8s.io/kind-mdr-container` from its finalizers. Foreign
clusters, control-plane containers, and changed identities are rejected.

The watcher creates a new Machine and fresh worker container with new storage,
then joins it through kubeadm using a short-lived token from the control plane.
It uses the cluster's node image and containerd configuration. After Ready,
kindnet convergence, and pod DNS/API verification, it publishes the worker's
Machine annotation and label. No test signal or replacement gate is required.
The existing MDR E2E assertions run unchanged against this lifecycle.

`replacement.json` records the new container, `join.log` records kubeadm output,
and `complete.json` records success. Errors write `error.json` and exit nonzero.
Logs go to stdout/stderr. Deletion-request timeout is five minutes; replacement
has a fifteen-minute deadline. No timeout triggers forced recovery. Use a fresh
cluster and state directory for each run; restart recovery is not supported.
Python 3, kubectl, and the selected container engine are required. `KUBECTL` and
`CONTAINER_TOOL` can select executable paths. Provisioning targets the pinned
Kind v0.33.0 setup, kubeadm v1beta4, and the default IPv4 Kind network.

This replaces the Machine controllers for testing, not a cloud provider. It never
sets MDR conditions or changes desired MachineSet replicas. The standard MDR
image needs no runtime socket or additional operator permissions.
