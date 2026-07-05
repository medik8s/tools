## helper_scripts/install_rhwa_operators.sh

Install RHWA operators (NHC, SNR, NMO, MDR, FAR) on an OCP cluster. Tested on Clusterbot, BM, and HyperShift. With `--create-idms`, the script can generate and apply an ImageDigestMirrorSet from a custom catalog source.

See also: [cluster setup workflow](../rhwa_cluster_setup_workflow.md).

### Prerequisites

- A working OCP cluster (Clusterbot, BM lab, etc.) and `oc login`.
- Clone the repo or copy the full `helper_scripts/` directory (includes `lib/rhwa_utils.sh`, which `install_rhwa_operators.sh` sources).
- Tools on PATH:
  - `oc` — always required
  - `jq` — only when using `--create-idms`
  - `opm` — optional; needed for `--create-idms` when the same packages exist in multiple catalogs (multi-catalog clusters)

### Help output

```
$ ./helper_scripts/install_rhwa_operators.sh --help
################################################################################
Install all 6 RHWA operators: NHC, SNR, NMO, MDR, FAR, SBR.

Options:
  --channel CHANNEL     Subscription channel (default: stable)
  --catsrc NAME         CatalogSource name (default: redhat-operators)
  --catsrc-ns NS        CatalogSource namespace (default: openshift-marketplace)
  --namespace NS        Install operators into NS (default: openshift-workload-availability)
  --disable-nhc-plugin   Do not enable NHC console plugin (enabled by default)
  --approval MANUAL|AUTO InstallPlan approval (default: Automatic)
  --only LIST           Install only these operators (comma-separated: nhc,snr,nmo,mdr,far,sbr). Default: all.
  --create-idms         Wait for --catsrc to be READY, generate IDMS from latest catalog versions, apply it, then install
  --wait                Wait for all CSVs to succeed (default: true)
  --kubeconfig-from HOST (optional) Download kubeconfig from remote host via SSH (user: root).
                         Exports KUBECONFIG for this run.
  --kubeconfig-path PATH (optional) Remote path to kubeconfig when using --kubeconfig-from (default: /root/.kube/config).

Environment:
  NHC_CONSOLE_PLUGIN_NAME  ConsolePlugin.metadata.name (default: node-remediation-console-plugin)
  NHC_CONSOLE_PLUGIN_WAIT  Seconds to wait for that CR after CSV install (default: 300)

  Defaults: channel=stable, catsrc=redhat-operators, namespace=openshift-workload-availability, approval=Automatic, nhc-plugin=enabled
  --create-idms: wait for catalog READY, write <script-dir>/idms/imageDigestMirrorSet_<catsrc>.yaml, oc apply, then install
```

### Usage notes

Run from the repo root:

```bash
./helper_scripts/install_rhwa_operators.sh
```

Defaults: `channel=stable`, `catsrc=redhat-operators`, `namespace=openshift-workload-availability`, `approval=Automatic`, NHC console plugin enabled.

Common flags:

- `--catsrc latest-iib` — install from a custom CatalogSource (use `--catsrc-ns` if not in `openshift-marketplace`)
- `--channel ITN-2026-00040-stable` — custom subscription channel
- `--only nhc,far` — install a subset of operators
- `--create-idms` — generate IDMS from the catalog index (disconnected / Konflux IIB testing)
- `--kubeconfig-from root@<hostname>` — fetch kubeconfig over SSH for QE lab systems (see script comment on `StrictHostKeyChecking=accept-new`)

### Re-installing on an existing cluster

If operators were previously installed and CSVs show `Pending` / `ResolutionFailed` with *"CSV exists and is not referenced by a subscription"*, delete orphaned CSVs before re-running:

```bash
oc delete csv --all -n openshift-workload-availability
./helper_scripts/install_rhwa_operators.sh
```

For more options, see the Usage section in the script header.
