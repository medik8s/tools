#!/usr/bin/env bash
#
# Verify RHWA post-release artifacts on registry.redhat.io and OCP catalogs.
# When logged into the Konflux cluster, pulls image references from Release CRs.
# Otherwise, discovers images from the advisories GitLab repo.
#
# Usage:
#   ./verify-post-release.sh rhwa-4.22-1
#   ./verify-post-release.sh rhwa-4.22-1 --skip-fbc
#   ./verify-post-release.sh rhwa-4.22-1 -v

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASES_DIR="${SCRIPT_DIR}/../rhwa-releases"
REGISTRY="registry.redhat.io"
SKIP_FBC=false
VERBOSE=false

KONFLUX_NAMESPACE="rhwa-tenant"
ADVISORIES_PROJECT_ID="82080"
ADVISORIES_TENANT="rhwa-tenant"

usage() {
  cat <<EOF
Usage: $(basename "$0") RELEASE_NAME [OPTIONS]

Verify RHWA post-release artifacts are published on ${REGISTRY}
and visible in OCP catalogs.

When logged into the Konflux cluster, image references are pulled
from Release CR artifacts. Otherwise, images are discovered from
the advisories GitLab repo (requires GITLAB_PRIVATE_TOKEN).

RELEASE_NAME is a directory under rhwa-releases/ (e.g. rhwa-4.22-1).

Options:
  --skip-fbc    Skip FBC/OCP catalog verification
  -v, --verbose Show full skopeo inspect output
  -h, --help    Show this help

Examples:
  $(basename "$0") rhwa-4.22-1
  $(basename "$0") rhwa-4.22-1 --skip-fbc -v
EOF
  exit 0
}

if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  usage
fi

RELEASE_NAME="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-fbc)   SKIP_FBC=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Locate release directory (search across year subdirectories)
RELEASE_DIR=""
for year_dir in "${RELEASES_DIR}"/*/; do
  if [[ -d "${year_dir}${RELEASE_NAME}" ]]; then
    RELEASE_DIR="${year_dir}${RELEASE_NAME}"
    break
  fi
done

if [[ -z "$RELEASE_DIR" ]]; then
  echo "Error: release directory not found for '${RELEASE_NAME}' under ${RELEASES_DIR}/"
  echo "Available releases:"
  find "${RELEASES_DIR}" -mindepth 2 -maxdepth 2 -type d -printf "  %f\n" 2>/dev/null | sort
  exit 1
fi

for cmd in skopeo jq yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found in PATH"
    exit 1
  fi
done

# Detect Konflux cluster access
HAS_KONFLUX=false
if command -v oc &>/dev/null; then
  current_server=$(oc whoami --show-server 2>/dev/null || true)
  [[ "$current_server" == *"stone-prod-p02"* ]] && HAS_KONFLUX=true
fi

total=0
passed=0
failed=0
failures=()

check_image() {
  local label="$1" image="$2"
  total=$((total + 1))

  printf "  %-65s " "$label"

  local inspect_output
  if inspect_output=$(skopeo inspect --no-tags "docker://$image" 2>&1); then
    local digest
    digest=$(echo "$inspect_output" | jq -r '.Digest // "unknown"')
    echo -e "\033[32mOK\033[0m  ${digest:0:25}"
    if $VERBOSE; then
      echo "$inspect_output" | jq '{version: .Labels.version, release: .Labels.release, architecture: .Labels.architecture}' 2>/dev/null | sed 's/^/    /'
    fi
    passed=$((passed + 1))
  else
    echo -e "\033[31mFAIL\033[0m"
    if $VERBOSE; then
      echo "    ${inspect_output}" | head -3
    fi
    failed=$((failed + 1))
    failures+=("$label: $image")
  fi
}

quay_to_registry() {
  echo "$1" | sed 's|quay.io/redhat-prod/|registry.redhat.io/|; s|----|/|'
}

# Parse release YAMLs — separate operator vs FBC
declare -a operator_yamls=() fbc_yamls=()

for yaml in "${RELEASE_DIR}"/*.yaml; do
  [[ -f "$yaml" ]] || continue
  name=$(yq '.metadata.name' "$yaml" 2>/dev/null) || continue

  if [[ "$name" == *fbc* ]]; then
    fbc_yamls+=("$yaml")
  else
    operator_yamls+=("$yaml")
  fi
done

if [[ ${#operator_yamls[@]} -eq 0 ]] && [[ ${#fbc_yamls[@]} -eq 0 ]]; then
  echo "Error: no release YAMLs found in ${RELEASE_DIR}/"
  exit 1
fi

# Extract FBC snapshot info for the banner
declare -A fbc_snapshots=() fbc_apps=()
for yaml in "${fbc_yamls[@]}"; do
  fbc_base=$(basename "$yaml" .yaml)
  snapshot=$(yq '.spec.snapshot' "$yaml" 2>/dev/null) || continue
  release_plan=$(yq '.spec.releasePlan' "$yaml" 2>/dev/null) || continue
  fbc_app="${release_plan%-releaseplan-*}"
  ocp_short=$(echo "$fbc_base" | grep -oP 'fbc-\K\d+' || true)
  if [[ -n "$ocp_short" ]]; then
    ocp_major="${ocp_short:0:1}"
    ocp_minor="${ocp_short:1}"
    fbc_snapshots["${ocp_major}.${ocp_minor}"]="$snapshot"
    fbc_apps["${ocp_major}.${ocp_minor}"]="$fbc_app"
  fi
done

echo "=============================================="
echo " RHWA Post-Release Verification"
echo " Release:  ${RELEASE_NAME}"
echo " Registry: ${REGISTRY}"
echo " Source:   ${RELEASE_DIR}"
if $HAS_KONFLUX; then
  echo " Mode:     Konflux (Release CRs)"
else
  echo " Mode:     Offline (advisories repo)"
fi
echo " Date:     $(date -u '+%Y-%m-%d %H:%M UTC')"
if [[ ${#fbc_snapshots[@]} -gt 0 ]]; then
  echo ""
  echo " FBC Snapshots:"
  for ocp_ver in $(echo "${!fbc_snapshots[@]}" | tr ' ' '\n' | sort); do
    echo "   OCP ${ocp_ver}: ${fbc_snapshots[$ocp_ver]} (${fbc_apps[$ocp_ver]})"
  done
fi
echo "=============================================="
echo ""

if $HAS_KONFLUX; then
  # ── Konflux mode ──

  if [[ ${#operator_yamls[@]} -gt 0 ]]; then
  echo "--- Operator Releases ---"
  for yaml in "${operator_yamls[@]}"; do
    cr_name=$(yq '.metadata.name' "$yaml" 2>/dev/null) || continue

    total=$((total + 1))
    printf "  %-65s " "$cr_name"

    release_json=$(oc get releases.appstudio.redhat.com "$cr_name" -n "$KONFLUX_NAMESPACE" -o json 2>/dev/null) || {
      echo -e "\033[31mNOT FOUND\033[0m"
      failed=$((failed + 1))
      failures+=("Release CR $cr_name not found on cluster")
      continue
    }

    released=$(echo "$release_json" | jq -r '.status.conditions[]? | select(.type == "Released") | .status' 2>/dev/null)
    reason=$(echo "$release_json" | jq -r '.status.conditions[]? | select(.type == "Released") | .reason' 2>/dev/null)
    advisory_url=$(echo "$release_json" | jq -r '.status.artifacts.advisory.url // empty' 2>/dev/null)

    if [[ "$released" == "True" ]]; then
      echo -en "\033[32mReleased\033[0m"
      [[ -n "$advisory_url" ]] && echo -n "  ${advisory_url}"
      echo ""
      passed=$((passed + 1))

      while IFS=$'\t' read -r img_name img_url; do
        [[ -z "$img_url" ]] && continue
        registry_url=$(quay_to_registry "$img_url")
        check_image "  ${img_name}" "$registry_url"
      done < <(echo "$release_json" | jq -r '
        .status.artifacts.images[]? |
        .name as $name |
        (.urls[]? | select(test("^quay.*:v[0-9]+\\.[0-9]+\\.[0-9]+$"))) as $url |
        [$name, $url] | @tsv' 2>/dev/null)

    elif [[ "$reason" == "Progressing" ]]; then
      echo -e "\033[33mIN PROGRESS\033[0m"
      failed=$((failed + 1))
      failures+=("$cr_name still progressing")
    else
      echo -e "\033[31mFAIL\033[0m (${reason:-unknown})"
      failed=$((failed + 1))
      failures+=("$cr_name status=${reason:-unknown}")
    fi
  done
  echo ""
  fi

  if ! $SKIP_FBC && [[ ${#fbc_yamls[@]} -gt 0 ]]; then
    echo "--- FBC Catalog Releases ---"
    for yaml in "${fbc_yamls[@]}"; do
      cr_name=$(yq '.metadata.name' "$yaml" 2>/dev/null) || continue

      total=$((total + 1))
      printf "  %-65s " "$cr_name"

      release_json=$(oc get releases.appstudio.redhat.com "$cr_name" -n "$KONFLUX_NAMESPACE" -o json 2>/dev/null) || {
        echo -e "\033[31mNOT FOUND\033[0m"
        failed=$((failed + 1))
        failures+=("Release CR $cr_name not found on cluster")
        continue
      }

      released=$(echo "$release_json" | jq -r '.status.conditions[]? | select(.type == "Released") | .status' 2>/dev/null)
      reason=$(echo "$release_json" | jq -r '.status.conditions[]? | select(.type == "Released") | .reason' 2>/dev/null)

      if [[ "$released" == "True" ]]; then
        echo -e "\033[32mReleased\033[0m"
        passed=$((passed + 1))

        while IFS=$'\t' read -r ocp_version target_index; do
          [[ -z "$target_index" ]] && continue
          registry_url=$(quay_to_registry "$target_index")
          check_image "  OCP ${ocp_version} catalog index" "$registry_url"
        done < <(echo "$release_json" | jq -r '
          .status.artifacts.components[]? |
          [.ocp_version, .target_index] | @tsv' 2>/dev/null)

      elif [[ "$reason" == "Progressing" ]]; then
        echo -e "\033[33mIN PROGRESS\033[0m"
        failed=$((failed + 1))
        failures+=("$cr_name still progressing")
      else
        echo -e "\033[31mFAIL\033[0m (${reason:-unknown})"
        failed=$((failed + 1))
        failures+=("$cr_name status=${reason:-unknown}")
      fi
    done
    echo ""
  fi

else
  # ── Offline mode: discover images from advisories GitLab repo ──

  if [[ -z "${GITLAB_PRIVATE_TOKEN:-}" ]]; then
    echo "Error: GITLAB_PRIVATE_TOKEN required for offline mode (advisories repo access)"
    exit 1
  fi

  GITLAB_API="https://gitlab.cee.redhat.com/api/v4"

  if [[ ${#operator_yamls[@]} -gt 0 ]]; then
    # Build operator entries from YAML filenames
    # far-0-8-1-prod.yaml + releasePlan far-0-8-releaseplan-prod → stream=far-0.8, version=0.8.1
    declare -a op_apps=()
    declare -A op_streams op_versions
    for yaml in "${operator_yamls[@]}"; do
      release_plan=$(yq '.spec.releasePlan' "$yaml" 2>/dev/null) || continue
      app="${release_plan%-releaseplan-*}"
      app_short="${app%%-[0-9]*}"
      version_nums="${app#"${app_short}"-}"
      stream="${app_short}-${version_nums//-/.}"

      base=$(basename "$yaml" .yaml)
      base="${base%-prod*}"
      patch="${base#"${app}"-}"
      full_version="${version_nums//-/.}.${patch}"

      op_apps+=("$app")
      op_streams["$app"]="$stream"
      op_versions["$app"]="$full_version"
    done

    release_year=$(basename "$(dirname "$RELEASE_DIR")")

    advisory_ids=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_PRIVATE_TOKEN" \
      "${GITLAB_API}/projects/${ADVISORIES_PROJECT_ID}/repository/tree?path=data/advisories/${ADVISORIES_TENANT}/${release_year}&per_page=100" \
      | jq -r '.[].name' | sort -rn)

    # Cache advisory metadata to temp files (one fetch per advisory)
    advisory_tmpdir=$(mktemp -d)
    trap 'rm -rf "$advisory_tmpdir"' EXIT
    echo "  Fetching advisory metadata..."
    for aid in $advisory_ids; do
      curl -s --header "PRIVATE-TOKEN: $GITLAB_PRIVATE_TOKEN" \
        "${GITLAB_API}/projects/${ADVISORIES_PROJECT_ID}/repository/files/data%2Fadvisories%2F${ADVISORIES_TENANT}%2F${release_year}%2F${aid}%2Fadvisory.yaml/raw?ref=main" \
        > "${advisory_tmpdir}/${aid}.yaml" 2>/dev/null
    done

    echo "--- Operator Releases (from advisories) ---"
    for app in "${op_apps[@]}"; do
      stream="${op_streams[$app]}"
      version="${op_versions[$app]}"

      # Find advisory matching this product_stream AND version tag
      matched_id=""
      matched_type=""
      for aid in $advisory_ids; do
        aid_stream=$(yq '.spec.product_stream' "${advisory_tmpdir}/${aid}.yaml" 2>/dev/null)
        if [[ "$aid_stream" == "$stream" ]]; then
          has_tag=$(yq -o json '.spec.content.images' "${advisory_tmpdir}/${aid}.yaml" 2>/dev/null \
            | jq -r --arg v "v${version}" '.[]?.tags[]? | select(. == $v)' 2>/dev/null | head -1)
          if [[ -n "$has_tag" ]]; then
            matched_id="$aid"
            matched_type=$(yq '.spec.type' "${advisory_tmpdir}/${aid}.yaml" 2>/dev/null)
            break
          fi
        fi
      done

      if [[ -z "$matched_id" ]]; then
        total=$((total + 1))
        printf "  %-65s " "${app} (${stream} v${version})"
        echo -e "\033[31mNO ADVISORY\033[0m"
        failed=$((failed + 1))
        failures+=("No advisory found for ${stream} v${version}")
        continue
      fi

      errata_url="https://access.redhat.com/errata/${matched_type}-${release_year}:${matched_id}"

      total=$((total + 1))
      printf "  %-65s " "${app} advisory (${matched_type}-${release_year}:${matched_id})"
      http_code=$(curl -s -o /dev/null -w '%{http_code}' "$errata_url" 2>/dev/null || echo "000")
      if [[ "$http_code" == "200" ]]; then
        echo -e "\033[32mOK\033[0m  ${errata_url}"
        passed=$((passed + 1))
      else
        echo -e "\033[31mFAIL\033[0m (HTTP ${http_code})"
        failed=$((failed + 1))
        failures+=("Advisory not accessible: ${errata_url}")
      fi

      # Verify images with the exact version tag
      while IFS=$'\t' read -r repo tag; do
        [[ -z "$repo" || -z "$tag" ]] && continue
        check_image "  ${repo##*/} (${tag})" "${repo}:${tag}"
      done < <(yq -o json '.spec.content.images' "${advisory_tmpdir}/${matched_id}.yaml" 2>/dev/null \
        | jq -r --arg v "v${version}" '
          [.[] | {repo: .repository, tag: (.tags[]? | select(. == $v))}]
          | unique_by(.repo)
          | .[]
          | [.repo, .tag] | @tsv' 2>/dev/null)
    done
    echo ""
  fi

  if ! $SKIP_FBC && [[ ${#fbc_snapshots[@]} -gt 0 ]]; then
    echo "--- FBC Catalog Indexes ---"
    for ocp_ver in $(echo "${!fbc_snapshots[@]}" | tr ' ' '\n' | sort); do
      catalog="${REGISTRY}/redhat/redhat-operator-index:v${ocp_ver}"
      check_image "OCP v${ocp_ver} catalog index" "$catalog"
    done
    echo ""
  fi
fi

if ! $SKIP_FBC; then
  echo "  Tip: verify on a running cluster with:"
  echo "    oc get packagemanifests -n openshift-marketplace | \\"
  echo "      grep -iE 'fence-agents|self-node|node-health|node-maint|machine-deletion|storage-based'"
fi

echo ""
echo "=============================================="
echo " Results: ${passed}/${total} passed, ${failed} failed"
echo "=============================================="

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for f in "${failures[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

exit 0
