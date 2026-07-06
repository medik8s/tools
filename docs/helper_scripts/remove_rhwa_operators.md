## helper_scripts/remove_rhwa_operators.sh

Remove RHWA operators (NHC, SNR, NMO, MDR, FAR) from all namespaces. Cleans up Subscriptions, CSVs, OLM v1 ClusterExtensions, stale OLM v0 ClusterRoles, custom resources, and CRDs.

See also: [cluster setup workflow](../rhwa_cluster_setup_workflow.md).

### Prerequisites

- `oc login` to the target cluster (or use `--kubeconfig-from` for QE lab hosts).
- Clone the repo or copy the `helper_scripts/` directory.

### Usage

```bash
./helper_scripts/remove_rhwa_operators.sh
./helper_scripts/remove_rhwa_operators.sh --only nhc,far
./helper_scripts/remove_rhwa_operators.sh --kubeconfig-from root@lab-host.example.com
```

### Options

| Option | Description |
|--------|-------------|
| `--only LIST` | Remove only listed operators (`nhc`, `snr`, `nmo`, `mdr`, `far`). Default: all five. |
| `--kubeconfig-from HOST` | Fetch kubeconfig over SSH (defaults to `root@`). See script comment on `StrictHostKeyChecking=accept-new`. |
| `--kubeconfig-path PATH` | Remote kubeconfig path (default: `/root/.kube/config`) |
| `-h` / `--help` | Show usage |

### What it removes

1. Subscriptions and CSVs for selected operators (all namespaces)
2. OLM v1 ClusterExtensions (if present)
3. Stale OLM v0 ClusterRoles (`*-metrics-reader`, `*-ext-remediation`) that block OLM v1 installs
4. OperatorGroup `workload-availability-operator-group` (only when removing all five operators; skipped with `--only`)
5. Custom resources and CRDs for selected operators

The `openshift-workload-availability` namespace is left in place for reinstall. Delete it manually if desired.

### Re-install after removal

```bash
./helper_scripts/remove_rhwa_operators.sh
./helper_scripts/install_rhwa_operators.sh
```
