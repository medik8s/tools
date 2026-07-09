# Medik8s Development Environment

A shared, consistent development environment for all medik8s operators.

## Quick Start

```bash
# One-time: add the dev environment snippet to your operator's Makefile
# (see Setup section below for options)

make dev-setup          # Create Kind cluster
make dev-deploy         # Build and deploy operator
make dev-describe       # Verify everything is running
make dev-simulate-failure && kubectl get nodes -w  # Test remediation
make dev-recover        # Restore cluster
make dev-teardown       # Clean up
```

### Full Walkthrough (NHC + SNR)

This walks through the complete remediation flow: deploy both operators,
simulate a node failure, and watch NHC trigger SNR to remediate it.

```bash
# 1. Deploy SNR (creates Kind cluster on first run)
pushd self-node-remediation
make dev-setup
make dev-deploy
popd

# 2. Deploy NHC (auto-creates NodeHealthCheck CR linking to SNR)
pushd node-healthcheck-operator
make dev-deploy
popd

# 3. Verify everything is running
make dev-wait
make dev-describe

# 4. Simulate a node failure
make dev-simulate-failure

# 5. Watch the remediation flow (run in separate terminals)
kubectl get nodes -w
kubectl get selfnoderemediation -A -w
make dev-events

# 6. Debug if needed
make dev-logs                          # tail operator logs
make dev-describe                      # full resource summary
make dev-summary                       # remediation flow timeline
make dev-shell                         # shell into a worker node

# 7. Recover all workers
make dev-recover

# 8. Teardown
make dev-teardown
```

## Prerequisites

- [Go](https://go.dev/doc/install) (version matching the operator's go.mod)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) (v0.22.0+, for K8s 1.29+ compatibility)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) or [oc](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)
- [Docker](https://docs.docker.com/get-docker/) or [Podman](https://podman.io/getting-started/installation)
- [operator-sdk](https://sdk.operatorframework.io/docs/installation/) (optional, for OLM bundle testing)

### System limits

The setup script checks inotify limits and exits with an error if they are too low (auto-fixes when running as root). Fix manually before running `make dev-setup`:

```bash
sudo sysctl -w fs.inotify.max_user_instances=8192
sudo sysctl -w fs.inotify.max_user_watches=524288
```

To make persistent, add to `/etc/sysctl.d/99-kind.conf`:
```
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
```

### Podman rootless setup

Rootless podman requires `cpuset` cgroup delegation for Kind worker nodes. Without it, kubelet cannot start inside the containers. The setup script detects this and prints instructions.

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/delegate.conf <<EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload
```

**You must log out and log back in** for the changes to take effect. After that, all commands work without `sudo`.

## Setup

Add the following snippet at the end of your operator's Makefile:

```makefile
# Shared dev environment
# Uses a local sibling checkout if available (e.g. ../tools),
# otherwise downloads the tools repo into .tools/ on first dev-* target use.
#
# IMPORTANT: Do NOT use $(shell git clone ...) here — $(shell) executes at
# Makefile parse time, so any make invocation (make build, make test, make help)
# would trigger a git clone. The dev-% fallback rule below is lazy: the clone
# only runs when a dev-* target is actually invoked.
TOOLS_DIR ?= $(shell cd .. && pwd)/tools
DEV_MK := $(TOOLS_DIR)/dev/dev.mk
ifeq ($(wildcard $(DEV_MK)),)
  TOOLS_DIR := $(shell pwd)/.tools
  DEV_MK := $(TOOLS_DIR)/dev/dev.mk
endif
-include $(DEV_MK)
ifeq ($(wildcard $(DEV_MK)),)
dev-%:
	@echo "Downloading medik8s/tools into $(TOOLS_DIR)..."
	@if [ -d $(TOOLS_DIR) ]; then echo "  Removing stale $(TOOLS_DIR)..."; rm -rf $(TOOLS_DIR); fi
	@git clone --depth 1 https://github.com/medik8s/tools.git $(TOOLS_DIR)
	@test -f $(DEV_MK) || { echo "Error: $(DEV_MK) not found after clone."; exit 1; }
	@$(MAKE) $@
endif
```

Add `.tools/` to your `.gitignore`:
```
echo '.tools/' >> .gitignore
```

To update the downloaded copy, delete it and re-run:
```bash
rm -rf .tools && make dev-help
```

All `dev-*` targets are now available.

## What It Creates

- **1 control-plane + 3 worker nodes** (SNR needs 2+ workers for peer health; use `KIND_HA=true` for 3 CP + 3 workers)
- **Worker labels** (`node-role.kubernetes.io/worker`)
- **softdog** kernel module on workers (for SNR/SBR watchdog testing)
- **Namespaces**: `medik8s-system` (privileged PSA) and `medik8s-leases` for shared resources
- **cert-manager** (required for operator webhook TLS certificates)
- **inotify limits** increased automatically when running as root
- **OLM** (if operator-sdk is available; uses `operator-sdk olm install` which installs OLM v0 — OLM v1 requires separate setup)

Re-running `make dev-setup` on an existing cluster is safe — it re-applies configuration without recreating.

**Note:** Each operator deploys into its own namespace (e.g. `self-node-remediation`, `node-healthcheck-operator-system`) as defined in its kustomization files (either `config/default/kustomization.yaml` or a component/patch kustomization). The `dev-deploy` target automatically creates cert-manager certificates, patches the deployment to mount webhook TLS secrets, and waits for the deployment to become ready. If NHC and a remediator (SNR, FAR, or MDR) are both deployed, it also creates a NodeHealthCheck CR linking them.

## Failure Simulations

| Command | What it does |
|---------|-------------|
| `make dev-simulate-failure` | Stop kubelet on a worker → node goes NotReady → NHC creates remediation CR |
| `make dev-simulate-network` | Block API server from a worker → tests SNR peer health decisions |
| `make dev-simulate-storm` | Stop kubelet on 2/3 workers → NHC detects storm, pauses remediation |
| `make dev-recover` | Restart kubelet, restore network, clean up CRs |

## All Targets

| Target | Description |
|--------|-------------|
| `dev-setup` | Create Kind cluster with all dependencies (`SKIP_KIND=true` for external cluster, `KIND_HA=true` for 3 CP + 3 workers) |
| `dev-teardown` | Destroy Kind cluster |
| `dev-build` | Build operator image and load into Kind (or push to ttl.sh) |
| `dev-deploy` | Build + install CRDs + deploy + configure cert-manager |
| `dev-redeploy` | Rebuild and restart (deletes pods to pick up new image) |
| `dev-undeploy` | Remove operator from cluster |
| `dev-bundle-run` | Deploy operator via OLM bundle (requires operator-sdk) |
| `dev-bundle-cleanup` | Remove OLM bundle deployment |
| `dev-create-nhc` | Create NodeHealthCheck CR (auto-detects SNR/FAR/MDR remediator) |
| `dev-logs` | Tail operator controller-manager logs |
| `dev-describe` | Full summary (nodes, pods, CRs, leases, events) |
| `dev-summary` | Remediation flow timeline |
| `dev-events` | Show recent remediation-related events |
| `dev-wait` | Wait for all operator pods to be ready |
| `dev-shell` | Open a shell on a Kind node (`NODE=<name>`, default: first worker) |
| `dev-simulate-failure` | Stop kubelet on a worker |
| `dev-simulate-storm` | Stop kubelet on 2 workers |
| `dev-simulate-network` | Block API server from a worker |
| `dev-recover` | Recover all workers and clean up |
| `dev-help` | Show all dev targets |

## Using an Existing Cluster (OCP, etc.)

For external clusters (OCP, etc.), set `SKIP_KIND=true` to skip Kind
creation. Images are pushed to [ttl.sh](https://ttl.sh) — an anonymous,
ephemeral registry that requires no auth.

```bash
# Point kubectl at your cluster, then use the same workflow
export KUBECONFIG=~/.kube/my-ocp-cluster
export SKIP_KIND=true

make dev-setup     # Configures namespaces + cert-manager (no Kind)
make dev-deploy    # Builds image, pushes to ttl.sh, deploys
make dev-describe  # Verify everything is running
```

Exporting `SKIP_KIND=true` ensures all targets know this is an external cluster.
Without it, auto-detection might find a local Kind cluster and use the wrong
image delivery method.

You can also use ttl.sh with a Kind cluster:

```bash
DEV_REGISTRY=ttl.sh make dev-deploy
```

**Note:** Failure simulations (`dev-simulate-failure`, etc.) require
`docker exec`/`podman exec` access to Kind node containers. On external
clusters, trigger failures through your cluster's own mechanisms.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `KIND_HA` | `false` | Set to `true` for HA cluster (3 CP + 3 workers, for SNR CP testing) |
| `SKIP_KIND` | `false` | Set to `true` to skip Kind creation (external cluster) |
| `DEV_REGISTRY` | `local` (Kind) / `ttl.sh` (external) | Image delivery: `local` or `ttl.sh` |
| `DEV_IMG` | auto-generated | Override to use a custom image name |
| `TTL_SH_TTL` | `2h` | Image expiry when using ttl.sh |
| `MEDIK8S_CLUSTER_NAME` | `medik8s-dev` | Kind cluster name |
| `CONTAINER_TOOL` | auto-detected | `docker` or `podman` |
| `KUBECTL` | auto-detected | `kubectl` or `oc` |
| `NHC_UNHEALTHY_DURATION` | `300s` | Unhealthy condition duration for NHC CR |

## Operator Coverage

| Operator | Coverage | Notes |
|----------|----------|-------|
| NHC | Full | Node conditions, storm recovery, escalation, CP protection |
| NMO | Full | Cordon, drain, PDB-aware eviction. Pod restarts on startup (missing namespace `list` RBAC — NMO bug, stabilizes after ~4 restarts). |
| SNR | ~85% | Peer health, softdog watchdog, API check. No hardware watchdog. |
| FAR | Controller logic | No real fence agents — controller reconciliation is testable |
| MDR | Controller logic | No Machine API — reconciliation testable via envtest (`make test`) |
| SBR | Unit only | No shared storage. Leader election RBAC error on startup (SBR bug). |

## Limitations

- **FAR fence agent execution** — no IPMI/BMC or cloud APIs
- **MDR Machine API** — Kind has no Machine objects
- **SBR shared storage** — no ODF
- **Hardware watchdog** — only softdog (software)
- **SNR `${IMG}` placeholders** — SNR manifests use `${IMG}` placeholders expanded by `envsubst`. The `dev-deploy` target handles this automatically, but running `kustomize build config/default | kubectl apply -f -` directly will produce `InvalidImageName` errors. The SNR controller reconciles DaemonSets from templates baked into the image, so image patches don't persist — always use `make dev-deploy` or `make dev-redeploy` for SNR.

For full-fidelity testing of these scenarios, use an OpenShift cluster with real hardware (BMC/IPMI for FAR, Machine API for MDR, ODF for SBR, hardware watchdog for SNR). The `SKIP_KIND=true` workflow supports deploying to external clusters.
