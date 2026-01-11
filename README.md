# tools

This repo is aimed to include many Dragonfly project files that are common to all.
The repo layout is:

- `.gitlab/merge_request_templates` directory for Merge Requests (MR) templates across the Dragonfly project.
- `.tekton` directory for PR and push Tekton PipelineRuns that test the Tekton Pipelines from shared-tekton-pipelines for CI/CD. PR and push files per each image/pipeline we would like to test
- `containers` directory for dummy containerfiles (of regular and fbc images) that are used in the container build of the Tekton PipelineRuns under `.tekton` directory
- `releases` directory for Konflux release CRs for each RHWA release
  - Includes a directory for each RHWA release with Konflux since we have migrated to Konflux (2025).
  - Includes a `automate_release_yamls.sh` script for creating an FBC or non-FBC release YAML. - Run `./releases/automate_release_yamls.sh usage` for help and view the below examples:
    - `./releases/automate_release_yamls.sh non-fbc 26.1 sbr-0-1 0 hkncb prod`
    - `./releases/automate_release_yamls.sh fbc 26.1 4.20 6l6qg prod tp`
- `shared-tekton-pipelines` directory for the shared Tekton Pipelines which are used in many Dragonfly operators under RHWA product
- `renovate-config` directory renovate config preset files (see [Inherited Config](https://konflux.pages.redhat.com/docs/users/mintmaker/user.html#inherited-config) and [RHWA-552](https://issues.redhat.com/browse/RHWA-552))
  - Includes a default preset for RHWA repos with Git Submodules and Containerfiles changes.
  - Includes a RHWA preset for RHWA repos with RPMs and external packages dependencies.
- `renovate.json` for Mintmaker/Renovate configuration of automatic MR to update the shared Tekton Pipelines tasks
