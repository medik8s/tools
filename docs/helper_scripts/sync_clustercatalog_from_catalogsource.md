## helper_scripts/sync_clustercatalog_from_catalogsource.sh

Align OLM v1 `ClusterCatalog` with a classic OLM `CatalogSource` (same catalog image ref). Merges CatalogSource `spec.secrets` into the cluster global pull-secret so catalogd can pull private index images (e.g. brew). Creates the `ClusterCatalog` if it does not exist.

See also: [cluster setup workflow](../rhwa_cluster_setup_workflow.md).

### Setup

1. Clone the repo or copy the full `helper_scripts/` directory (includes `lib/rhwa_utils.sh`, which this script sources).
2. `oc login` to the target cluster.
3. Ensure the source `CatalogSource` exists (e.g. from `iib_deployment/deploy_iib.sh` or a Konflux brew catalog).
4. Run the script (patch existing ClusterCatalog or create a new one).

### Usage

```bash
./helper_scripts/sync_clustercatalog_from_catalogsource.sh
./helper_scripts/sync_clustercatalog_from_catalogsource.sh \
  --CATSRC_NAME=rhwa-release-catalog-brew \
  --CLUSTERCATALOG_NAME=rhwa-release-cluster-catalog-brew
```

### Options

Also available as env vars or `VAR=value` positional args:

| Option | Default | Description |
|--------|---------|-------------|
| `--CATSRC_NAME` | `redhat-operators` | Source CatalogSource name |
| `--CATSRC_NS` | `openshift-marketplace` | CatalogSource namespace |
| `--CLUSTERCATALOG_NAME` | `openshift-redhat-operators` | Target ClusterCatalog name |
| `--CLUSTERCATALOG_LABEL` | same as name | `olm.operatorframework.io/metadata.name` label on create |
| `--CLUSTERCATALOG_PRIORITY` | `-100` | Priority on create (lower than official catalogs; won't shadow them) |
| `--CATSRC_WAIT_TIMEOUT` | `600` | Seconds to wait for CatalogSource READY |
| `--CATALOG_WAIT_TIMEOUT` | `600` | Seconds to wait for ClusterCatalog Serving |
| `--SYNC_PULL_SECRETS` | on | Merge CatalogSource secrets into global pull-secret |
| `--SKIP_PULL_SECRET_SYNC` | — | Skip global pull-secret merge |
| `--WAIT` | on | Wait for CatalogSource READY + ClusterCatalog Serving |
| `--NO_WAIT` | — | Skip waits after patch/create |
| `-h` / `--help` | — | Show usage |

### Behavior

Wait for CatalogSource READY → merge pull secrets into `openshift-config/pull-secret` (restart catalogd if changed) → patch or create `ClusterCatalog` → wait for Serving.

### Konflux brew example

```bash
./helper_scripts/sync_clustercatalog_from_catalogsource.sh \
  --CATSRC_NAME=rhwa-release-catalog-brew \
  --CLUSTERCATALOG_NAME=rhwa-release-cluster-catalog-brew
```
