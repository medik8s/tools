#!/bin/bash

create_fbc_releases_snr() {
	err_str="Usage $0 <RELEASE> <OPERATOR_VERSION> <OCP> <SNAPSHOT_SUFFIX> [is_stage]. Please try again"

    local release="${1?$err_str}"
    local operator_version="${2?$err_str}"
	local ocp="${3?$err_str}"
    local snapshot_suffix="${4?$err_str}"
	local is_stage="${5:-"stage"}"

    cat <<EOF > "${release}"/"${release}"-"${operator_version}"-fbc-"${ocp}"-"${is_stage}"-ga.yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: rhwa-${release}-${operator_version}-fbc-${ocp}-${is_stage}-ga
  namespace: rhwa-tenant
spec:
  releasePlan: ${operator_version}-fbc-${ocp}-releaseplan-${is_stage}
  snapshot: ${operator_version}-fbc-${ocp}-${snapshot_suffix}
EOF
}
automate_fbc_releases() {
    local is_stage="${1:-"stage"}"
    # Define your snapshot_list
    snapshot_list=(
        "414,snr-0-10-fbc-414-sv2l2"
        "415,snr-0-10-fbc-415-h6jj2"
        "416,snr-0-10-fbc-416-nxtmt"
        "417,snr-0-10-fbc-417-985jj"
        "418,snr-0-10-fbc-418-n8vn9"
        "419,snr-0-10-fbc-419-7fg46"
    )
    # Loop through each item in the snapshot_list
    for entry in "${snapshot_list[@]}"; do
        # IFS=',' read -r -a parts <<< "$entry"
         local IFS=','
        # Create an array by splitting the string. This works because when IFS is set,
        # Bash will split the string "$entry" into words, and the parentheses create an array.
        local parts=($entry) # No quotes here, so word splitting happens by IFS
        unset IFS #
        local ocp_version="${parts[0]}"
        local snapshot_id="${parts[1]}"
        echo "${ocp_version} and ${snapshot_id}"
        create_fbc_releases_snr "rhwa-25.2" "${ocp_version}" "${snapshot_id}" "${is_stage}"
    done
}