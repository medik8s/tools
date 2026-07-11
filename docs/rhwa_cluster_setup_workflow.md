## RHWA cluster setup workflow

End-to-end order for deploying RHWA operators from internal IIB or Konflux catalogs on a test cluster.

### Pipeline overview

```mermaid
flowchart LR
  A[deploy_iib.sh] --> B[install_rhwa_operators.sh]
  B -.->|uninstall| C[remove_rhwa_operators.sh]
```

| Step | Script | When to use |
|------|--------|-------------|
| 1 | `helper_scripts/deploy_iib.sh` | Deploy a brew/IIB CatalogSource (+ optional IDMS). Use `--olm v1` for ClusterCatalog. Skip if the catalog already exists. |
| 2 | `helper_scripts/install_rhwa_operators.sh` | Install all six RHWA operators. OLM v0 (default): Subscriptions. OLM v1: `--olm v1` for ClusterExtension. Use `--create-idms` when testing disconnected/Konflux mirrors. |

Shared helpers live in `helper_scripts/lib/rhwa_utils.sh` (catalog wait, pull-secret merge, ClusterCatalog Serving wait).

**IDMS note:** IDMS is only needed when installing operators from unverified/brew catalogs (IIB). The default `redhat-operators` catalog does not require IDMS.

### Example: OLM v0 (classic OLM) with brew IIB catalog

```bash
# 1. Deploy IIB catalog
./helper_scripts/deploy_iib.sh 1141449 --convert-secret

# 2. Install operators (add --create-idms for Konflux mirror mapping)
./helper_scripts/install_rhwa_operators.sh \
  --catsrc rhwa-iib-1141449 \
  --catsrc-ns openshift-operators \
  --create-idms
```

### Example: OLM v1 (ClusterExtension) with brew IIB catalog

```bash
# 1. Deploy IIB as ClusterCatalog directly
./helper_scripts/deploy_iib.sh 1141449 --olm v1 --convert-secret

# 2. Install operators via ClusterExtension
./helper_scripts/install_rhwa_operators.sh \
  --olm v1 \
  --catsrc rhwa-iib-1141449
```

### Example: connected cluster with redhat-operators

```bash
./helper_scripts/install_rhwa_operators.sh
```

No IIB deploy needed when using the default `redhat-operators` catalog.

### Per-script documentation

- [install_rhwa_operators.sh](helper_scripts/install_rhwa_operator.md)
- [remove_rhwa_operators.sh](helper_scripts/remove_rhwa_operators.md)

### Troubleshooting

- **CSV stuck Pending / ResolutionFailed after re-run:** orphaned CSVs from a prior install — run `remove_rhwa_operators.sh` or `oc delete csv --all -n openshift-workload-availability`, then re-run install.
- **IDMS generation fails on multi-catalog cluster:** install `opm` on the machine running the install script.
