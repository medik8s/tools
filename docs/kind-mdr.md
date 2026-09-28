# MDR Machine lifecycle simulation

`dev/kind_mdr.py` implements a single prepared-spare replacement on a disposable
Docker Kind cluster. The MDR repository's `hack/kind-e2e.sh` owns cluster setup,
operator deployment, E2E execution, and teardown. Existing SNR/SBR reboot and FAR
fence-agent behavior is separate from this mode.

Prepare a fresh fixture before deploying MDR:

```bash
python3 dev/kind_mdr.py prepare --name mdr-kind-e2e --state-dir /tmp/mdr-run \
  --crd-dir ../machine-deletion-remediation/vendor/github.com/openshift/api/machine/v1beta1/zz_generated.crd-manifests
```

Preparation requires one Ready control plane and three Ready workers. It drains
and stops the last worker by sorted name, removes its Node, installs the vendored
Machine/MachineSet CRDs, and creates two linked Machines in `kind-mdr-machines`.
It records Node, Machine, owner, and container identities in `fixture.json`.
Use `KUBECONFIG` for the named Kind cluster and `CONTAINER_TOOL=docker`.

Start the watcher through the shared entry point:

```bash
dev/kind-reboot-watcher.sh --mode mdr --once --name mdr-kind-e2e --state-dir /tmp/mdr-run
```

The `ready` file signals fixture validation. A fixture Machine's deletion
timestamp triggers removal of its recorded container, UID-guarded Node deletion,
and removal of only `medik8s.io/kind-mdr-container` from its finalizers. Foreign
clusters, control-plane containers, and changed identities are rejected.

After observing the Machine gone and MDR's intermediate conditions, the test
creates `replace-<machine-uid>` in the state directory. The watcher creates a
replacement Machine, starts the spare, waits for Ready and kindnet subnet
convergence, and verifies pod DNS/API connectivity before publishing the worker
annotation and label. Success writes `complete.json`; errors write `error.json`
and exit nonzero. Logs go to stdout/stderr for the caller to capture.

Deletion-request timeout is five minutes; replacement release and readiness share
a fifteen-minute deadline. No timeout triggers forced recovery. Use a fresh cluster and
state directory after failure or success; restart recovery and additional spares
are outside this simulator's scope. Python 3, Docker, and kubectl are required.
`KUBECTL` and `CONTAINER_TOOL` can select the executable paths.

This is a test double for Machine controllers, not a cloud provider. It never
sets MDR conditions or changes desired MachineSet replicas. It uses the standard
MDR image without Docker socket mounts or additional operator permissions.
