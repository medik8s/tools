# tools

This repo is aimed to include many Dragonfly project files that are common to all.
The repo layout is:

- `.gitlab/merge_request_templates` directory for Merge Requests (MR) templates across the Dragonfly project.
- `.tekton` directory for PR and push Tekton PipelineRuns that test the Tekton Pipelines from shared-tekton-pipelines for CI/CD. PR and push files per each image/pipeline we would like to test
- `containers` directory for dummy containerfiles (of regular and fbc images) that are used in the container build of the Tekton PipelineRuns under `.tekton` directory
- `releases` directory for Konflux release CRs for each RHWA release
  - Includes a directory for each RHWA release with Konflux since we have migrated to Konflux (2025).
  - Includes a script for creating  FBC or non-FBC release YAML.
    - Option A - Run `./releases/create_release.sh DIR_NAME FBC_APP STAGED_IIB`. Find related snapshots from staged IIB and create release YAMLs (FBC and non-fbc) under `DIR_NAME`.
    - Option B - Run `./releases/automate_release_yamls.sh usage` for help and view the below examples:
      - `./releases/automate_release_yamls.sh non-fbc 26.1 sbr-0-1 0 hkncb prod`
      - `./releases/automate_release_yamls.sh fbc 26.1 4.20 6l6qg prod tp`
- `shared-tekton-pipelines` directory for the shared Tekton Pipelines which are used in many Dragonfly operators under RHWA product
- `renovate-config` directory renovate config preset files (see [Inherited Config](https://konflux.pages.redhat.com/docs/users/mintmaker/user.html#inherited-config) and [RHWA-552](https://issues.redhat.com/browse/RHWA-552))
  - Includes a default preset for RHWA repos with Git Submodules and Containerfiles changes.
  - Includes a RHWA preset for RHWA repos with RPMs and external packages dependencies.
- `renovate.json` for Mintmaker/Renovate configuration of automatic MR to update the shared Tekton Pipelines tasks
- `helper_scripts` directory for cluster helper scripts used by QE and lab workflows:
  - `deploy_iib.sh` — deploy a brew/IIB catalog via OLM v0 (CatalogSource) or v1 (ClusterCatalog), with optional IDMS
  - `install_rhwa_operators.sh` — install RHWA operators via classic OLM (optional IDMS generation)
  - `sync_clustercatalog_from_catalogsource.sh` — align OLMv1 `ClusterCatalog` with a `CatalogSource`
  - `lib/rhwa_utils.sh` — shared catalog helpers (sourced by the scripts above; not run directly)
  - See [cluster setup workflow](docs/rhwa_cluster_setup_workflow.md), [install doc](docs/helper_scripts/install_rhwa_operator.md), and [sync doc](docs/helper_scripts/sync_clustercatalog_from_catalogsource.md)

## How to Manually Update RPMs

> **Note:** MintMaker now supports automatic `rpms.lock.yaml` regeneration when bumping base images via the [`refresh-rpm-lockfiles`](https://github.com/konflux-ci/mintmaker-presets) preset ([KONFLUX-11483](https://redhat.atlassian.net/browse/KONFLUX-11483)). The manual process below is needed only when adding/removing packages or troubleshooting.

Read [RHWA-171](https://redhat.atlassian.net/browse/RHWA-171) for the initial issue (see past changes at [FAR MR 339](https://gitlab.cee.redhat.com/dragonfly/fence-agents-remediation/-/merge_requests/339), [FAR MR 349](https://gitlab.cee.redhat.com/dragonfly/fence-agents-remediation/-/merge_requests/349)) for how we set it up and why. The [Konflux RPM lockfile docs](https://konflux.pages.redhat.com/docs/users/building/activation-keys-subscription.html#configuring-an-rpm-lockfile-for-hermetic-builds) are the best source for enabling new and removing old packages, and then creating a new `rpms.lock.yaml` for hermetic builds.

Below are the steps assuming the repo was already onboarded (using FAR as an example):

1. Enter the FAR repo directory.
2. Run a UBI container matching your current base image:
   ```bash
   podman run --rm -it -v $(pwd):/source:Z registry.access.redhat.com/ubi9/ubi-minimal:9.6-1755695350
   ```
   Use the tag from your [Containerfile](https://gitlab.cee.redhat.com/dragonfly/fence-agents-remediation/-/blob/far-0-8/Containerfile.fence-agents-remediation?ref_type=heads#L17).
3. Install the tools needed to run a [recent rpm-lockfile-prototype](https://github.com/konflux-ci/rpm-lockfile-prototype/tags):
   ```bash
   microdnf install -y subscription-manager pip skopeo python3-dnf vi
   pip install --user https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/tags/v0.21.0.tar.gz
   ```
4. Register with your activation key:
   ```bash
   subscription-manager register --activationkey="$KEY_NAME" --org="$ORG_ID"
   ```
5. Copy the default repository file configured by subscription-manager to the source directory:
   ```bash
   cp /etc/yum.repos.d/redhat.repo /source/redhat.repo
   ```
6. Substitute the current architecture with `$basearch` in `redhat.repo` to facilitate fetching for multiple architectures:
   ```bash
   sed -i "s/$(uname -m)/\$basearch/g" /source/redhat.repo
   ```
7. Authenticate to the Red Hat container registry using your Red Hat Customer Portal credentials:
   ```bash
   skopeo login registry.redhat.io
   ```
8. Generate the lockfile:
   ```bash
   cd /source; rpm-lockfile-prototype -f Containerfile.fence-agents-remediation rpms.in.yaml
   ```

### SSL Key & Cert

After generating the lockfile, replace the hardcoded SSL certificate and key paths in `redhat.repo` with `$SSL_CLIENT_CERT` and `$SSL_CLIENT_KEY` variables for MintMaker automatic updates:

```bash
sed -i 's|sslclientcert=/etc/pki/entitlement-host/.*\.pem|sslclientcert=$SSL_CLIENT_CERT|' /source/redhat.repo
sed -i 's|sslclientkey=/etc/pki/entitlement-host/.*-key\.pem|sslclientkey=$SSL_CLIENT_KEY|' /source/redhat.repo
```

See [RPM lockfile with RPMs that require subscription](https://konflux.pages.redhat.com/docs/users/mintmaker/rpm-lockfile.html#rpm-lockfile-with-rpms-that-require-subscription).

### Multiple Architectures (Optional)

> **Note:** This section is only needed when the Containerfile installs different packages per architecture (e.g., FAR's cloud fence agents are only available on x86_64). If all architectures install the same packages, `rpm-lockfile-prototype` resolves them in a single run and this section can be skipped.

When packages differ across architectures, `rpm-lockfile-prototype` will fail trying to resolve all of them at once. Instead, generate a separate lockfile per architecture: run step 8, save the resulting `rpms.lock.yaml` with an arch-specific name (e.g., `rpms.lock.x86_64.yaml`), modify `rpms.in.yaml` for the next architecture, and re-run step 8. Then combine the lockfiles by appending the `arches` blocks:

```bash
LINE=$(grep -n '^- arch:' rpms.lock.s390x.yaml | head -1 | cut -d: -f1)
cp rpms.lock.x86_64.yaml rpms.lock.yaml
tail -n +$LINE rpms.lock.s390x.yaml >> rpms.lock.yaml
```
