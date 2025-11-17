#!/bin/bash

#
# This script generates a Kubernetes Release custom resource YAML file for FBC operators.
# It accepts command-line arguments to specify the necessary parameters.
# Usage: ./create_release.sh <RELEASE> <OPERATOR_VERSION> <SNAPSHOT_SUFFIX> [is_stage] [advisory_type]

create_non_fbc_release() {
    # Define an error string for missing mandatory arguments
    local err_str="Usage: $0 <RELEASE> <OPERATOR_VERSION> <PATCH_VERSION> <SNAPSHOT_SUFFIX> [is_stage] [advisory_type]. A mandatory argument is missing."

    # Assign arguments to local variables.
    # The ${1?err_str} syntax will cause the script to exit with an error if the argument is not provided.
    local release="${1?$err_str}"
    local operator_version="${2?$err_str}"
    local patch_version="${3?$err_str}"
    local snapshot_suffix="${4?$err_str}"
    # Assign the 5th argument to is_stage, defaulting to "stage" if it's not provided.
    local is_stage="${5:-"stage"}"
    local advisory_type="${6:-"RHEA"}" # RHEA, RHBA, RHSA, etc.  Default to RHEA if not provided.
    # Construct the final output filename based on the user's request.
    local output_filename="${operator_version}-${patch_version}-${is_stage}-ga.yaml"

    # Create the YAML file using a 'here document'.
    # The content between cat <<EOF and EOF is written to the specified output file.
    cat <<EOF > "${output_filename}"
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: ${operator_version}-${patch_version}-${is_stage}-ga
  namespace: rhwa-tenant
spec:
  releasePlan: ${operator_version}-releaseplan-${is_stage}
  snapshot: ${operator_version}-${snapshot_suffix}
  data:
    releaseNotes:
      type: ${advisory_type}
      references:
       - https://docs.redhat.com/en/documentation/workload_availability_for_red_hat_openshift/${release}
EOF

    # Inform the user that the file has been created successfully.
    echo "\nSuccess! YAML file created: ${output_filename}"
}

create_fbc_release() {
    # Define an error string for missing mandatory arguments
    local err_str="Usage: $0 <RELEASE> <OCP> <SNAPSHOT_SUFFIX> [is_stage]. A mandatory argument is missing."

    # Assign arguments to local variables.
    # The ${1?err_str} syntax will cause the script to exit with an error if the argument is not provided.
    local release="${1?$err_str}"
    local ocp="${2?$err_str}"
    local snapshot_suffix="${3?$err_str}"
    # Assign the 5th argument to is_stage, defaulting to "stage" if it's not provided.
    local is_stage="${4:-"stage"}"
    # Construct the final output filename based on the user's request.
    local output_filename="rhwa-${release}-fbc-${ocp}-${is_stage}.yaml"

    # Create the YAML file using a 'here document'.
    # The content between cat <<EOF and EOF is written to the specified output file.
    cat <<EOF > "${output_filename}"
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: rhwa-${release}-fbc-${ocp}-${is_stage}-ga
  namespace: rhwa-tenant
spec:
  releasePlan: rhwa-fbc-${ocp}-releaseplan-${is_stage}
  snapshot: rhwa-fbc-${ocp}-${snapshot_suffix}
EOF

    # Inform the user that the file has been created successfully.
    echo "\nSuccess! FBC Release YAML file was successfully created: ${output_filename}"
}
