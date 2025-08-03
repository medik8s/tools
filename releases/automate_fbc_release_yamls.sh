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
    local ocp="${3?$err_str}"
    local snapshot_suffix="${4?$err_str}"
    # Assign the 5th argument to is_stage, defaulting to "stage" if it's not provided.
    local is_stage="${5:-"stage"}"

    # Construct the final output filename based on the user's request.
    local output_filename="releases/rhwa-${release}/rhwa-${release}-fbc-${ocp}-${is_stage}-ga.yaml"

    # Create the YAML file using a 'here document'.
    # The content between cat <<EOF and EOF is written to the specified output file.
    cat <<EOF > "${output_filename}"
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: rhwa-${release}-fbc-${ocp}-${is_stage}-ga
  namespace: rhwa-tenant
spec:
  releasePlan: ${operator_version}-fbc-${ocp}-releaseplan-${is_stage}
  snapshot: ${operator_version}-fbc-${ocp}-${snapshot_suffix}
EOF

    # Inform the user that the file has been created successfully.
    echo "" # Add a newline for better formatting
    echo "Success! YAML file created: ${output_filename}"
}
