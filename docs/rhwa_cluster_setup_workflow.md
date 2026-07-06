## RHWA cluster setup workflow

End-to-end order for deploying RHWA operators from internal IIB or Konflux catalogs on a test cluster.

### Pipeline overview

```mermaid
flowchart LR
  A[deploy_iib.sh] --> B[sync_clustercatalog.sh]
  B --> C[install_rhwa_operators.sh]
  C -.->|uninstall| D[remove_rhwa_operators.sh]
```

| Step | Script | When to use |
|------|--------|-------------|
| 1 | `helper_scripts/deploy_iib.sh` | Deploy a brew/IIB CatalogSource (+ optional IDMS). Skip if the catalog already exists. |
| 2 | `helper_scripts/sync_clustercatalog_from_catalogsource.sh` | OLM v1 clusters: align `ClusterCatalog` with the CatalogSource and merge brew pull secrets. Skip on classic OLM-only clusters. |
| 3 | `helper_scripts/install_rhwa_operators.sh` | Install all six RHWA operators via Subscriptions. Use `--create-idms` when testing disconnected/Konflux mirrors. |

Shared helpers live in `helper_scripts/lib/rhwa_utils.sh` (catalog wait, pull-secret merge, ClusterCatalog Serving wait).

**IDMS note:** IDMS is only needed when installing operators from unverified/brew catalogs (IIB). The default `redhat-operators` catalog does not require IDMS.

### Example: OCP 5.x nightly with brew catalog

```bash
# 1. Deploy IIB catalog (optional if catalog already present)
./helper_scripts/deploy_iib.sh 1141449 --convert-secret

# 2. Sync OLM v1 ClusterCatalog (OLM v1 / operator-controller clusters)
./helper_scripts/sync_clustercatalog_from_catalogsource.sh \
  --CATSRC_NAME=rhwa-iib-1141449 \
  --CLUSTERCATALOG_NAME=rhwa-iib-1141449-cluster-catalog

# 3. Install operators (add --create-idms for Konflux mirror mapping)
./helper_scripts/install_rhwa_operators.sh \
  --catsrc rhwa-iib-1141449 \
  --catsrc-ns openshift-operators \
  --create-idms
```

### Example: connected cluster with redhat-operators

```bash
./helper_scripts/install_rhwa_operators.sh
```

No IIB deploy or ClusterCatalog sync needed when using the default `redhat-operators` catalog on classic OLM.

### Per-script documentation

- [install_rhwa_operators.sh](helper_scripts/install_rhwa_operator.md)
- [remove_rhwa_operators.sh](helper_scripts/remove_rhwa_operators.md)
- [sync_clustercatalog_from_catalogsource.sh](helper_scripts/sync_clustercatalog_from_catalogsource.md)

### Troubleshooting

- **CSV stuck Pending / ResolutionFailed after re-run:** orphaned CSVs from a prior install — run `remove_rhwa_operators.sh` or `oc delete csv --all -n openshift-workload-availability`, then re-run install.
- **ClusterCatalog not Serving:** ensure brew pull secrets were merged (`--SYNC_PULL_SECRETS`, default on).
- **IDMS generation fails on multi-catalog cluster:** install `opm` on the machine running the install script.
