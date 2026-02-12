#!/bin/bash

echo "DEPRECATED! Use create_release.sh instead"
exit 0

# This script generates a Kubernetes Release custom resource YAML file for FBC operators.
# It accepts command-line arguments to specify the necessary parameters.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

create_non_fbc_release() {
    # Define an error string for missing mandatory arguments
    local err_str
    err_str="Usage: $(basename "$0") non-fbc <RELEASE> <OPERATOR_VERSION> <PATCH_VERSION> <SNAPSHOT_SUFFIX> [is_stage] [advisory_type]. A mandatory argument is missing."

    local release="${1?$err_str}" # release directory name should be the raw release name, with dot
    local operator_version="${2?$err_str}"
    local patch_version="${3?$err_str}"
    local snapshot_suffix="${4?$err_str}"
    local is_stage="${5:-"stage"}" # "stage" or "prod" if not provided, default to "stage"
    local advisory_type="${6:-"RHEA"}" # RHEA, RHBA, RHSA, etc.  Default to RHEA if not provided.
    # Construct the final output filename based on the user's request.
    local output_filename="${script_dir}/rhwa-${release}/${operator_version}-${patch_version}-${is_stage}.yaml"
    mkdir -p "$(dirname -- "${output_filename}")"

    cat <<EOF > "${output_filename}"
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: ${operator_version}-${patch_version}-${is_stage}
  namespace: rhwa-tenant
spec:
  releasePlan: ${operator_version}-releaseplan-${is_stage}
  snapshot: ${operator_version}-${snapshot_suffix}
  data:
    releaseNotes:
      type: ${advisory_type}
EOF

    echo "Success! YAML file created: ${output_filename}"
}

create_fbc_release() {
    # Define an error string for missing mandatory arguments
    local err_str
    err_str="Usage: $(basename "$0") fbc <RELEASE> <OCP> <SNAPSHOT_SUFFIX> [is_stage] [is_ga]. A mandatory argument is missing."

    local release_raw="${1?$err_str}" # release directory name should be the raw release name, with dot replaced by hyphen.
    local release="${release_raw//./-}"
    local ocp_raw="${2?$err_str}"
    local ocp="${ocp_raw//./}"
    local snapshot_suffix="${3?$err_str}"
    local is_stage="${4:-"stage"}" # "stage" or "prod" if not provided, default to "stage"
    local is_ga
    is_ga="${5:-"ga"}" # "tp" or "ga" if not provided, default to "ga"
    if [[ "${is_ga}" != "tp" && "${is_ga}" != "ga" ]]; then
        echo "Invalid GA flag '${is_ga}'. Use 'tp' or 'ga'." >&2
        exit 1
    fi
    local ga_suffix=""
    if [[ "${is_stage}" == "prod" ]]; then
        ga_suffix="-${is_ga}"
    fi
    # Construct the final output filename based on the user's request.
    local output_filename="${script_dir}/rhwa-${release_raw}/rhwa-${release}-fbc-${ocp}-${is_stage}${ga_suffix}.yaml"
    mkdir -p "$(dirname -- "${output_filename}")"

    cat <<EOF > "${output_filename}"
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: rhwa-${release}-fbc-${ocp}-${is_stage}${ga_suffix}
  namespace: rhwa-tenant
spec:
  releasePlan: rhwa-fbc-${ocp}-releaseplan-${is_stage}
  snapshot: rhwa-fbc-${ocp}-${snapshot_suffix}
EOF

    echo "Success! FBC Release YAML file was successfully created: ${output_filename}"
}

usage() {
    cat <<EOF
Usage:
  $(basename "$0") non-fbc <RELEASE> <OPERATOR_VERSION> <PATCH_VERSION> <SNAPSHOT_SUFFIX> [is_stage] [advisory_type]
    - example: $(basename "$0") non-fbc 26.1 sbr 0 1-0 prod RHBA

  $(basename "$0") fbc     <RELEASE> <OCP> <SNAPSHOT_SUFFIX> [is_stage] [is_ga]
    - OCP version dots are stripped (4.20 -> 420)
    - is_stage: stage|prod (suffix for tp/ga only when prod)
    - is_ga: tp|ga (default ga; rejected otherwise)
    - example: $(basename "$0") fbc 26.1 4.20 snap123 prod tp
EOF
}

main() {
    local mode="${1:-}"
    case "${mode}" in
        non-fbc)
            shift
            create_non_fbc_release "$@"
            ;;
        fbc)
            shift
            create_fbc_release "$@"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
