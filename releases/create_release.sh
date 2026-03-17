#!/usr/bin/env bash

# This script generates new release configs
#
# There are some input parameters:
# 1. a release name
# 2. the FBC name
# 2. the IIB number which was used by QE
#
# The release name will be used as directory name.
# The IIB is used for
# - finding the staged catalog release, which produced that IIB
# - finding the snapshot catalog
# - finding related operator snapshots
#
# For each operator snaphot a release manifest is created.
# Finally for the catalog snapshot a release is created.
#
# Manual actions for now:
# - add Jira tickets as needed
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

expected_cluster_name="stone-prod-p02"
rhwa_namespace="rhwa-tenant"

# Check if we are logged in
cluster_name=$(oc config view --minify -o jsonpath='{.clusters[].name}')
if [[ "$cluster_name" != *"$expected_cluster_name"* ]]; then
    echo "Error: not logged in to correct cluster: $cluster_name"
    exit 1
fi

echo "Heads up, you need to be logged in with podman to quay.io/redhat-user-workloads!"

# Check arguments
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <release_name> <fbc_name> <iib_number>"
    echo "<release_name> can be anything but should be useful of course, it's used as directory name"
    echo "e.g.: ./create_release.sh hotfix-cap910-420 rhwa-fbc-420-hotfix 1102942"
    exit 1
fi

release_name="$1"
fbc_name="$2"
iib_number="$3"

# find staged catalog for the given IIB
fbc_releases=$(oc -n ${rhwa_namespace} get releases -l appstudio.openshift.io/application=${fbc_name} -o custom-columns=:metadata.name --no-headers)
fbc_release=""
fbc_snapshot=""

while IFS= read -r release; do
    echo "checking release ${release} for IIB"
    release_manifest=$(oc -n ${rhwa_namespace} get releases ${release} -o yaml)
    iib=$(echo "${release_manifest}" | yq '.status.artifacts.index_image.[].index_image')
    if [[ "$iib" == *":${iib_number}" ]]; then
        fbc_release=${release}
        fbc_snapshot=$(echo "${release_manifest}" | yq '.spec.snapshot')
        fbc_release_plan=$(echo "${release_manifest}" | yq '.spec.releasePlan')

        cat > "${SCRIPT_DIR}/fbc_to_release.yaml" <<EOF
fbc_release: ${fbc_release}
fbc_snapshot: ${fbc_snapshot}
fbc_release_plan: ${fbc_release_plan}
EOF

        break
    fi
done <<< "$fbc_releases"

if [[ -z "$fbc_release" ]]; then
    echo "Error: no release found for IIB ${iib_number}"
    exit 1
fi
if [[ -z "$fbc_snapshot" ]]; then
    echo "Error: no snapshot found in release ${fbc_release}"
    exit 1
fi

echo "Found matching release ${fbc_release} with snaphot ${fbc_snapshot}"

fbc_image=$(oc -n ${rhwa_namespace} get snapshots ${fbc_snapshot} -o yaml | yq '.spec.components.[]'.containerImage)

# Extract /configs from the FBC image
tmp_dir=$(mktemp -d -p "${SCRIPT_DIR}")
container_id=$(podman create "${fbc_image}")
podman cp "${container_id}:/configs" "${tmp_dir}/configs"
podman rm "${container_id}"

# Iterate extracted directories and ask which bundles to release
bundles_file="${SCRIPT_DIR}/bundles_to_release.yaml"
echo "bundles:" > "${bundles_file}"

for dir in "${tmp_dir}/configs"/*/; do
    catalog_file="${dir}catalog.yaml"
    if [[ ! -f "$catalog_file" ]]; then
        continue
    fi

    # Extract bundle names from olm.bundle entries
    bundle_names=$(yq 'select(.schema == "olm.bundle") | .name' "${catalog_file}")

    while IFS= read -r -u 3 bundle_name; do
        [[ -z "$bundle_name" || "$bundle_name" == "---" ]] && continue
        read -p "Create release YAML for ${bundle_name}? [y/N] " answer
        if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
            bundle_image=$(yq "select(.schema == \"olm.bundle\" and .name == \"${bundle_name}\") | .image" "${catalog_file}")
            operator="${bundle_name%%.*}"
            version="${bundle_name#*.v}"
            major="${version%%.*}"
            rest="${version#*.}"
            minor="${rest%%.*}"
            patch="${rest#*.}"
            cat >> "${bundles_file}" <<EOF
  - name: ${bundle_name}
    operator: ${operator}
    major: ${major}
    minor: ${minor}
    patch: ${patch}
    image: ${bundle_image}
EOF
        fi
    done 3<<< "$bundle_names"
done

echo "Bundles to release saved in ${bundles_file}"

bundle_count=$(yq '.bundles | length' "${bundles_file}")
for (( i=0; i<bundle_count; i++ )); do
    name=$(yq ".bundles[${i}].name" "${bundles_file}")
    operator=$(yq ".bundles[${i}].operator" "${bundles_file}")
    major=$(yq ".bundles[${i}].major" "${bundles_file}")
    minor=$(yq ".bundles[${i}].minor" "${bundles_file}")
    image=$(yq ".bundles[${i}].image" "${bundles_file}")
    echo "Processing bundle: operator=${operator} major=${major} minor=${minor} image=${image}"

		operator_short=""
		case $operator in
				node-healthcheck-operator)
						operator_short="nhc"
						;;
				fence-agents-remediation)
						operator_short="far"
						;;
				self-node-remediation)
						operator_short="snr"
						;;
				machine-deletion-remediation)
						operator_short="mdr"
						;;
				node-maintenance-operator)
						operator_short="nmo"
						;;
				storage-based-remediation)
						operator_short="sbr"
						;;
				*)
						echo "Unknown operator: ${operator}"
						exit 1
						;;
		esac
		app="${operator_short}-${major}-${minor}"
		op_releases=$(oc -n ${rhwa_namespace} get releases -l appstudio.openshift.io/application=${app} -o custom-columns=:metadata.name --no-headers)

		# find release for the bundle
		bundle_name="\"${operator_short}-bundle-${major}-${minor}\""
		echo "bundle name $bundle_name"
		while IFS= read -r release; do
				release_manifest=$(oc -n ${rhwa_namespace} get releases ${release} -o yaml)
				bundle_shasum=$(echo "${release_manifest}" | yq ".status.artifacts.images[] | select ( .name == $bundle_name ) | .shasum")
				echo "sha: ${bundle_shasum}"
				if [[ "$image" == *"@${bundle_shasum}" ]]; then
						op_release=${release}
						op_snapshot=$(echo "${release_manifest}" | yq '.spec.snapshot')
						op_release_plan=$(echo "${release_manifest}" | yq '.spec.releasePlan')

						yq -i ".bundles[${i}].operator_short = \"${operator_short}\"" "${bundles_file}"
						yq -i ".bundles[${i}].op_release = \"${op_release}\"" "${bundles_file}"
						yq -i ".bundles[${i}].op_snapshot = \"${op_snapshot}\"" "${bundles_file}"
						yq -i ".bundles[${i}].op_release_plan = \"${op_release_plan}\"" "${bundles_file}"
						echo "found release $op_release for $bundle_name"
						break
				fi
		done <<< "$op_releases"

		if [[ -z "$op_release" ]]; then
				echo "Error: no release found for bundle ${bundle_name} with shasum matching image ${image}"
				exit 1
		fi

done

# Create release manifests
mkdir -p "${SCRIPT_DIR}/${release_name}"

# Operator releases
bundle_count=$(yq '.bundles | length' "${bundles_file}")
for (( i=0; i<bundle_count; i++ )); do
    operator_short=$(yq ".bundles[${i}].operator_short" "${bundles_file}")
    major=$(yq ".bundles[${i}].major" "${bundles_file}")
    minor=$(yq ".bundles[${i}].minor" "${bundles_file}")
    patch=$(yq ".bundles[${i}].patch" "${bundles_file}")
    op_snapshot=$(yq ".bundles[${i}].op_snapshot" "${bundles_file}")
    op_release_plan=$(yq ".bundles[${i}].op_release_plan" "${bundles_file}" | sed 's/-stage/-prod/')

    manifest_name="${operator_short}-${major}-${minor}-${patch}-prod"
    manifest_name="${manifest_name,,}"
    cat > "${SCRIPT_DIR}/${release_name}/${manifest_name}.yaml" <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: ${manifest_name}
  namespace: ${rhwa_namespace}
spec:
  releasePlan: ${op_release_plan}
  snapshot: ${op_snapshot}
  data:
    releaseNotes:
      type: RHBA
      issues:
        fixed:
          - id: REPLACE_ME
            source: issues.redhat.com
EOF
    echo "Created ${SCRIPT_DIR}/${release_name}/${manifest_name}.yaml"
done

# FBC catalog release
fbc_snapshot=$(yq '.fbc_snapshot' "${SCRIPT_DIR}/fbc_to_release.yaml")
fbc_release_plan=$(yq '.fbc_release_plan' "${SCRIPT_DIR}/fbc_to_release.yaml" | sed 's/-stage/-prod/')

timestamp=$(date +%Y%m%d-%H%M)
fbc_manifest_name="${release_name}-${fbc_name}-prod-${timestamp}"
fbc_manifest_name="${fbc_manifest_name,,}"
cat > "${SCRIPT_DIR}/${release_name}/${fbc_manifest_name}.yaml" <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: ${fbc_manifest_name}
  namespace: ${rhwa_namespace}
spec:
  releasePlan: ${fbc_release_plan}
  snapshot: ${fbc_snapshot}
EOF

echo "Created ${SCRIPT_DIR}/${release_name}/${fbc_manifest_name}.yaml"
echo "add Jira issues as needed!"
