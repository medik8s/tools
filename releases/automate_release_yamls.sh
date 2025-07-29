#!/bin/bash

#
# This script generates a Kubernetes Release custom resource YAML file for FBC operators.
# It accepts command-line arguments to specify the necessary parameters.
# Usage: ./create_release.sh <RELEASE> <OPERATOR_VERSION> <OCP> <SNAPSHOT_SUFFIX> [is_stage]
#

# --- Core Function ---
# This function takes parameters and creates the FBC release operator YAML content.
# The output is redirected to a file with a name constructed from the arguments.
create_fbc_releases_operator() {
    # Define an error string for missing mandatory arguments
    local err_str="Usage: $0 <RELEASE> <OPERATOR_VERSION> <OCP> <SNAPSHOT_SUFFIX> [is_stage]. A mandatory argument is missing."

    # Assign arguments to local variables.
    # The ${1?err_str} syntax will cause the script to exit with an error if the argument is not provided.
    local release="${1?$err_str}"
    local operator_version="${2?$err_str}"
    local snapshot_suffix="${3?$err_str}"
    # Assign the 5th argument to is_stage, defaulting to "stage" if it's not provided.
    local is_stage="${4:-"stage"}"
    local type="${5:-"RHEA"}" # RHEA, RHBA, RHSA, etc.  Default to RHEA if not provided.
    # Construct the final output filename based on the user's request.
    local output_filename="rhwa-${release}/${operator_version}-1-${is_stage}-ga.yaml"

    # Create the YAML file using a 'here document'.
    # The content between cat <<EOF and EOF is written to the specified output file.
    cat <<EOF > "${output_filename}"
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: ${operator_version}-1-${is_stage}-ga
  namespace: rhwa-tenant
spec:
  releasePlan: ${operator_version}-releaseplan-${is_stage}
  snapshot: ${operator_version}-${snapshot_suffix}
  data:
    releaseNotes:
      type: ${type}
      references:
       - https://docs.redhat.com/en/documentation/workload_availability_for_red_hat_openshift/${release}
EOF

    # Inform the user that the file has been created successfully.
    echo "" # Add a newline for better formatting
    echo "Success! YAML file created: ${output_filename}"
}

# --- Main Script Execution ---
# Pass all command-line arguments received by the script ("$@") to the function.
# The function itself will validate that the required arguments have been provided.
create_fbc_releases_operator "$@"