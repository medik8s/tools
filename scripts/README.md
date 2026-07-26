# Scripts

All automation scripts for RHWA releases, Mintmaker, and cluster setup.

## Release & Mintmaker

| Script | Purpose |
|--------|---------|
| `create_release.sh` | Generate FBC and non-FBC release YAMLs from a staged IIB |
| `tag_downstream.sh` | Tag downstream GitLab repos from Konflux prod releases |
| `mintmaker-toggle.sh` | Toggle Mintmaker (Renovate) on Konflux components |
| `mintmaker-config.yaml` | Per-operator/version Mintmaker enable/disable config |

## Cluster Setup

| Script | Purpose |
|--------|---------|
| `deploy_iib.sh` | Deploy a brew/IIB CatalogSource (+ optional IDMS) |
| `install_rhwa_operators.sh` | Install RHWA operators via OLM v0 or v1 |
| `remove_rhwa_operators.sh` | Uninstall RHWA operators (subs, CSVs, CRs, CRDs, OLM v1 extensions) |
| `lib/rhwa_utils.sh` | Shared helpers (catalog wait, pull-secret merge) — sourced, not run directly |

## Documentation

- [Cluster setup workflow](docs/rhwa_cluster_setup_workflow.md) — end-to-end order
- [Install operators](docs/install_rhwa_operator.md)
- [Remove operators](docs/remove_rhwa_operators.md)
- [RPM lockfile update](docs/rpm_lockfile_update.md) — manual `rpms.lock.yaml` regeneration
- [RHWA test process](https://docs.google.com/document/d/1E-arB0rzqZzWzI-T5EaKPdEtNRqZjv-xS-BWUB8-Ink/edit?tab=t.xpsj2ngnkrf6#heading=h.6dbvd5b3xqvg)
