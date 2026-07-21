# tools

This repo includes shared Dragonfly project files common to all RHWA operators.

## Repo Layout

- `.gitlab/merge_request_templates` — MR templates for the Dragonfly project.
- `.tekton` — PR and push Tekton PipelineRuns that test the shared pipelines.
- `containers` — Dummy Containerfiles (regular and FBC) used by the `.tekton` PipelineRuns for CI container builds.
- `shared-tekton-pipelines` — Shared Tekton Pipelines used across Dragonfly operator repos under RHWA.
- `rhwa-releases` — Konflux release CRs for each RHWA release, organized by year.
  - `rhwa-releases/2025/` — Releases from 2025 (rhwa-25.x, hotfixes).
  - `rhwa-releases/2026/` — Releases from 2026 (rhwa-26.x, rhwa-4.2x).
- `scripts` — All automation scripts ([README](scripts/README.md)):
  - **Release:** `create_release.sh`, `tag_downstream.sh` — generate Konflux release YAMLs from staged IIBs and tag downstream GitLab repos.
  - **Mintmaker:** `mintmaker-toggle.sh`, `mintmaker-config.yaml` — enable or disable Mintmaker (Renovate) on Konflux components per operator and version.
  - **Cluster setup:** `deploy_catalog.sh`, `install_rhwa_operators.sh`, `remove_rhwa_operators.sh` — deploy operator catalogs (IIB or FBC) and install/remove all six RHWA operators on test clusters.
  - `lib/` — Shared helpers (catalog wait, pull-secret merge); `docs/` — per-script documentation.
- `renovate-config` — Renovate config preset files for other RHWA repos (see [Inherited Config](https://konflux.pages.redhat.com/docs/users/mintmaker/user.html#inherited-config) and [RHWA-552](https://issues.redhat.com/browse/RHWA-552)).
  - `default.json` — Default preset for repos with Git Submodules and Containerfiles.
  - `rhwa-rpms.json` — Preset for repos with RPMs and external package dependencies.
- `renovate.json` — Mintmaker config for **this repo** (auto-updates shared Tekton pipeline task digests). Not a preset — see `renovate-config/` for presets.

## Creating Release YAMLs

Run `./scripts/create_release.sh DIR_NAME FBC_APP STAGED_IIB` to find related snapshots from a staged IIB and create release YAMLs (FBC and non-FBC) under `rhwa-releases/`.

Example:
```bash
./scripts/create_release.sh hotfix-cap910-420 rhwa-fbc-420-hotfix 1102942
```

## Tagging Downstream Repos

Run `./scripts/tag_downstream.sh <fbc-app-name>` to resolve source commits from Konflux prod releases and create signed version tags on downstream GitLab repos.

```bash
./scripts/tag_downstream.sh rhwa-fbc-421
./scripts/tag_downstream.sh --commits-only rhwa-fbc-421
```

Override GitLab URLs via environment variables:
```bash
export GITLAB_BASE="git@gitlab.example.com:myorg"
export GITLAB_WEB="https://gitlab.example.com/myorg"
```

## How to Manually Update RPMs

See [RPM lockfile update guide](scripts/docs/rpm_lockfile_update.md).
