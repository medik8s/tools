# MDR Machine lifecycle simulation

[`dev/kind_mdr.py`](../dev/kind_mdr.py) simulates one Machine replacement on a
Podman or Docker Kind development cluster. For the complete OLM/E2E flow, run
`bash hack/local-run.sh all` from the MDR repository; see its
[Kind E2E guide](https://github.com/medik8s/machine-deletion-remediation/blob/main/docs/kind-e2e.md).
That runner handles setup, deployment, watcher supervision, and diagnostics.
It removes only clusters it creates and leaves pre-existing clusters intact.
SNR/SBR reboot and FAR behavior remain separate.

Use the shared `make dev-setup` defaults: `medik8s-dev`, `kind-registry:5000`,
one control plane and three workers. An existing Kind cluster with one Ready
control plane and at least two Ready workers is also supported. The following
manual commands run from the tools repository. Set `KUBECONFIG` to that Kind
cluster before preparing the fixture; its context must be `kind-<cluster-name>`:

```bash
python3 dev/kind_mdr.py prepare --name medik8s-dev \
  --crd-dir ../machine-deletion-remediation/vendor/github.com/openshift/api/machine/v1beta1/zz_generated.crd-manifests
```

Preparation installs the vendored Machine/MachineSet CRDs and creates the
`kind-mdr-machines` namespace, a MachineSet whose replicas match the worker
count, and a linked Machine for each worker. Machines have controller owner
references, `kind://` provider IDs, Node references, fixture labels, and the
simulator finalizer. Each worker receives its Machine annotation.
Preparation does not reserve or stop a container. Podman is the default;
set `CONTAINER_TOOL=docker` to use Docker consistently for both commands.

```bash
dev/kind-reboot-watcher.sh --mode mdr --once --name medik8s-dev
```

The watcher discovers the labeled Machines, their owner and Node references,
and Kind container identities from Kubernetes and the container engine. It keeps
that snapshot in memory. A fixture Machine's deletion
timestamp triggers removal of its recorded container, UID-guarded Node deletion,
and removal of only `medik8s.io/kind-mdr-container` from its finalizers. Foreign
clusters, control-plane containers, and changed identities are rejected.

The watcher creates a new Machine and fresh worker container with new storage,
then joins it through kubeadm using a short-lived token from the control plane.
It uses the cluster's node image and copies containerd and shared-registry
configuration from a healthy worker. It also copies that worker's resolved
registry hostname mapping into the new worker's `/etc/hosts`. Registry creation
and configuration of the original nodes remain the responsibility of
`make dev-setup`; no localhost registry alias is needed.
After Ready, kindnet convergence, and pod DNS/API verification, it publishes
the worker's Machine annotation and label. No test signal or replacement gate is required.
The existing MDR E2E assertions run unchanged against this lifecycle.

The watcher needs no state directory or coordination files. It logs the discovered
identities, new container ID, and kubeadm output to stdout. Exit zero means the
replacement was published successfully; errors go to stderr and exit nonzero.
The runner supervises that exit status and owns log/artifact collection.
Deletion-request timeout is five minutes; replacement has a fifteen-minute
deadline. No timeout triggers forced recovery. The fixture supports one MDR
replacement; resuming a partially completed replacement is not supported.
Other operators can reuse the cluster before or after this run. Preparation
rejects an existing fixture namespace; use a fresh cluster for another MDR run.

Python 3, kubectl, and the selected container engine are required. `KUBECTL` and
`CONTAINER_TOOL` can select executable paths. Provisioning targets the pinned
Kind v0.33.0 setup, kubeadm v1beta4, and the default IPv4 Kind network.

This replaces the Machine controllers for testing, not a cloud provider. It never
sets MDR conditions or changes desired MachineSet replicas during replacement.
It does not deploy NHC or run the separate system-tests suite. The standard MDR
image needs no runtime socket or additional operator permissions.
