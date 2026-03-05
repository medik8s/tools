#!/usr/bin/env bash
# tag_downstream.sh — Tag downstream GitLab repos from Konflux prod releases.
#
# Finds the latest FBC prod release in Konflux, extracts the operator bundles,
# resolves the source commits via skopeo inspect, and creates signed version
# tags on the downstream GitLab repos.
#
# Usage:
#   ./tag_downstream.sh [--commits-only] <fbc-app-name>
#
# Example:
#   ./tag_downstream.sh rhwa-fbc-421
#   ./tag_downstream.sh --commits-only rhwa-fbc-421
#
# Prerequisites:
#   - Logged into cluster stone-prod-p02 (oc CLI)
#   - podman login quay.io/redhat-user-workloads
#   - Tools: oc, podman, skopeo, yq, jq, git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

expected_cluster_name="stone-prod-p02"
rhwa_namespace="rhwa-tenant"
gitlab_base="git@gitlab.cee.redhat.com:dragonfly"
gitlab_web="https://gitlab.cee.redhat.com/dragonfly"

COMMITS_ONLY=false
FBC_APP=""

declare -A OP_REPO=(
    [snr]=self-node-remediation
    [far]=fence-agents-remediation
    [nmo]=node-maintenance-operator
    [nhc]=node-healthcheck-operator
    [mdr]=machine-deletion-remediation
    [sbr]=storage-based-remediation
)

declare -A REPO_TO_SHORT=()

log()  { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

TMP_DIR=""
cleanup() {
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    podman rm -f fbc-extract 2>/dev/null || true
}
trap cleanup EXIT

FBC_SNAPSHOT=""

declare -a BUNDLE_NAMES=()
declare -a BUNDLE_IMAGES=()

validate_prerequisites() {
    log "Validating prerequisites"

    for cmd in oc podman skopeo yq jq git; do
        command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found in PATH"
    done
    info "Required tools: OK"

    local cluster_name
    cluster_name=$(oc config view --minify -o jsonpath='{.clusters[].name}')
    [[ "$cluster_name" == *"$expected_cluster_name"* ]] || \
        die "Not logged into correct cluster (expected $expected_cluster_name, got: $cluster_name)"
    info "Cluster: OK ($cluster_name)"

    if podman login --get-login quay.io/redhat-user-workloads &>/dev/null; then
        info "Podman login: OK"
    else
        warn "Cannot verify podman login to quay.io/redhat-user-workloads — make sure you are logged in"
    fi
}

find_fbc_prod_release() {
    log "Finding latest FBC prod release for ${FBC_APP}"

    local releases
    releases=$(oc -n "${rhwa_namespace}" get releases \
        -l "appstudio.openshift.io/application=${FBC_APP}" \
        -o custom-columns=':metadata.name' --no-headers)

    [[ -n "$releases" ]] || die "No releases found for application ${FBC_APP}"

    local latest_release="" latest_ts=""

    while IFS= read -r release; do
        [[ -z "$release" ]] && continue
        local manifest
        manifest=$(oc -n "${rhwa_namespace}" get releases "${release}" -o yaml)
        local release_plan
        release_plan=$(echo "${manifest}" | yq '.spec.releasePlan')
        if [[ "$release_plan" == *-prod* ]]; then
            local timestamp
            timestamp=$(echo "${manifest}" | yq '.metadata.creationTimestamp')
            if [[ -z "$latest_ts" || "$timestamp" > "$latest_ts" ]]; then
                latest_ts="$timestamp"
                latest_release="$release"
                FBC_SNAPSHOT=$(echo "${manifest}" | yq '.spec.snapshot')
            fi
        fi
    done <<< "$releases"

    [[ -n "$latest_release" ]] || \
        die "No prod releases found for ${FBC_APP} (no releasePlan containing '-prod')"

    info "Release:  ${latest_release}"
    info "Snapshot: ${FBC_SNAPSHOT}"
    info "Created:  ${latest_ts}"
}

version_gt() {
    local -a a b
    IFS=. read -ra a <<< "$1"
    IFS=. read -ra b <<< "$2"
    for i in 0 1 2; do
        (( ${a[$i]:-0} > ${b[$i]:-0} )) && return 0
        (( ${a[$i]:-0} < ${b[$i]:-0} )) && return 1
    done
    return 1
}

extract_bundles_from_fbc() {
    log "Extracting bundles from FBC snapshot"

    local fbc_image
    fbc_image=$(oc -n "${rhwa_namespace}" get snapshots "${FBC_SNAPSHOT}" \
        -o jsonpath='{.spec.components[0].containerImage}')
    info "FBC image: ${fbc_image}"

    TMP_DIR=$(mktemp -d -p "${SCRIPT_DIR}")

    podman create --name fbc-extract "${fbc_image}" >/dev/null
    podman cp "fbc-extract:/configs" "${TMP_DIR}/configs"
    podman rm fbc-extract >/dev/null

    declare -A latest_version=()
    declare -A latest_bundle_name=()
    declare -A latest_bundle_image=()

    for dir in "${TMP_DIR}/configs"/*/; do
        local catalog_file="${dir}catalog.yaml"
        [[ -f "$catalog_file" ]] || continue

        local bundle_names
        bundle_names=$(yq 'select(.schema == "olm.bundle") | .name' "${catalog_file}")

        while IFS= read -r bundle_name; do
            [[ -z "$bundle_name" || "$bundle_name" == "---" ]] && continue

            local operator="${bundle_name%%.*}"
            local version="${bundle_name#*.v}"

            if [[ -z "${latest_version[$operator]:-}" ]] || version_gt "$version" "${latest_version[$operator]}"; then
                latest_version[$operator]="$version"
                latest_bundle_name[$operator]="$bundle_name"
                latest_bundle_image[$operator]=$(yq "select(.schema == \"olm.bundle\" and .name == \"${bundle_name}\") | .image" "${catalog_file}")
            fi
        done <<< "$bundle_names"
    done

    for operator in "${!latest_bundle_name[@]}"; do
        BUNDLE_NAMES+=("${latest_bundle_name[$operator]}")
        BUNDLE_IMAGES+=("${latest_bundle_image[$operator]}")
        info "Bundle: ${latest_bundle_name[$operator]}"
    done

    [[ ${#BUNDLE_NAMES[@]} -gt 0 ]] || die "No bundles found in FBC image"
    log "Found ${#BUNDLE_NAMES[@]} operator bundle(s)"
}

display_name() {
    local repo="$1"
    local image_name="$repo"
    [[ "$repo" == *-operator ]] || image_name="${repo}-operator"
    local display=""
    local -a words
    IFS='-' read -ra words <<< "${image_name}"
    for word in "${words[@]}"; do
        display+="${word^} "
    done
    echo "${display% }"
}

resolve_bundle_to_commit() {
    local op_short="$1" bundle_image="$2" major="$3" minor="$4"
    local app="${op_short}-${major}-${minor}"
    info "Looking up Konflux releases for application ${app}" >&2

    local op_releases
    op_releases=$(oc -n "${rhwa_namespace}" get releases \
        -l "appstudio.openshift.io/application=${app}" \
        -o custom-columns=':metadata.name' --no-headers)

    if [[ -z "$op_releases" ]]; then
        warn "No releases found for application ${app}"
        return 1
    fi

    local bundle_component_name="\"${op_short}-bundle-${major}-${minor}\""

    while IFS= read -r release; do
        [[ -z "$release" ]] && continue
        local manifest
        manifest=$(oc -n "${rhwa_namespace}" get releases "${release}" -o yaml)
        local bundle_shasum
        bundle_shasum=$(echo "${manifest}" | yq ".status.artifacts.images[] | select ( .name == ${bundle_component_name} ) | .shasum")

        [[ -n "$bundle_shasum" && "$bundle_image" == *"@${bundle_shasum}" ]] || continue

        info "Matched release: ${release}" >&2
        local op_snapshot
        op_snapshot=$(echo "${manifest}" | yq '.spec.snapshot')

        local bundle_component="${op_short}-bundle-${major}-${minor}"
        local snapshot_bundle_image
        snapshot_bundle_image=$(oc -n "${rhwa_namespace}" get snapshots "${op_snapshot}" -o yaml \
            | yq ".spec.components[] | select(.name == \"${bundle_component}\") | .containerImage")

        if [[ -z "$snapshot_bundle_image" ]]; then
            warn "Could not find bundle image in snapshot ${op_snapshot}"
            return 1
        fi

        info "Bundle image: ${snapshot_bundle_image}" >&2
        local commit
        commit=$(skopeo inspect "docker://${snapshot_bundle_image}" | jq -r '.Labels["vcs-ref"]')
        if [[ -z "$commit" || "$commit" == "null" ]]; then
            warn "No vcs-ref label found on image ${snapshot_bundle_image}"
            return 1
        fi
        info "Source commit: ${commit}" >&2
        echo "${commit}"
        return 0
    done <<< "$op_releases"

    warn "No matching release found for bundle image digest"
    return 1
}

resolve_tag_commit() {
    local remote="$1" tag="$2"
    local dereferenced
    dereferenced=$(git ls-remote --tags "${remote}" "refs/tags/${tag}^{}" 2>/dev/null | awk '{print $1}')
    if [[ -n "$dereferenced" ]]; then
        echo "$dereferenced"
        return
    fi
    git ls-remote --tags "${remote}" "refs/tags/${tag}" 2>/dev/null | awk '{print $1}'
}

verify_existing_tag() {
    local repo="$1" version="$2" expected_commit="$3"
    local tag="v${version}"
    local remote="${gitlab_base}/${repo}.git"

    local tag_commit
    tag_commit=$(resolve_tag_commit "$remote" "$tag")

    if [[ -z "$tag_commit" ]]; then
        echo "NEEDS TAG"
        return
    fi

    if [[ "$tag_commit" == "$expected_commit" ]]; then
        info "Tag ${tag} on ${repo} already points to ${expected_commit:0:12}" >&2
        echo "OK (tag matches)"
    else
        warn "Tag ${tag} on ${repo} points to ${tag_commit:0:12}, expected ${expected_commit:0:12}" >&2
        echo "MISMATCH ${tag_commit}"
    fi
}

tag_downstream_repo() {
    local repo="$1" version="$2" commit="$3" display="$4"
    local tag="v${version}"
    local remote="${gitlab_base}/${repo}.git"

    local existing_commit
    existing_commit=$(resolve_tag_commit "$remote" "$tag")

    if [[ -n "$existing_commit" ]]; then
        if [[ "$existing_commit" == "$commit" ]]; then
            info "Tag ${tag} on ${repo} already points to ${commit:0:12} — skipping" >&2
            echo "exists"
            return
        fi

        warn "Tag ${tag} on ${repo} points to ${existing_commit:0:12}, expected ${commit:0:12}" >&2
        read -rp "    Overwrite tag ${tag} on ${repo}? [y/N] " answer </dev/tty
        if [[ "$answer" != [yY] ]]; then
            info "Skipping ${tag} on ${repo} (user declined)" >&2
            echo "skipped"
            return
        fi
        info "Overwriting tag ${tag} on ${repo}" >&2
    fi

    local tmp_clone="/tmp/${repo}-tag-$$"
    if ! git clone --depth 1 "${remote}" "${tmp_clone}" 2>/dev/null; then
        warn "Failed to clone ${remote}"
        rm -rf "${tmp_clone}"
        echo "failed"
        return
    fi

    if ! git -C "${tmp_clone}" fetch --depth 1 origin "${commit}" 2>/dev/null; then
        warn "Commit ${commit} not found on ${repo}"
        rm -rf "${tmp_clone}"
        echo "failed"
        return
    fi

    if [[ -n "$existing_commit" ]]; then
        git -C "${tmp_clone}" push origin ":refs/tags/${tag}" 2>/dev/null
    fi

    git -C "${tmp_clone}" tag -s "${tag}" "${commit}" -m "${display} ${tag}"
    git -C "${tmp_clone}" push origin "${tag}"
    rm -rf "${tmp_clone}"

    info "Tag ${tag} created and pushed to ${repo}" >&2
    echo "created"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --commits-only) COMMITS_ONLY=true; shift ;;
            -h|--help)
                sed -n '2,/^$/{ s/^# \?//; p }' "${BASH_SOURCE[0]}"
                exit 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                [[ -z "$FBC_APP" ]] || die "Unexpected argument: $1 (FBC app already set to $FBC_APP)"
                FBC_APP="$1"; shift
                ;;
        esac
    done

    [[ -n "$FBC_APP" ]] || die "No FBC app name specified. Run with --help for usage."
}

commit_url() {
    local repo="$1" commit="$2"
    echo "${gitlab_web}/${repo}/-/commit/${commit}"
}

summary_line() {
    local op="$1" repo="$2" version="$3" commit="$4" status="$5" url="${6:-}"
    if [[ -n "$url" ]]; then
        printf '%-8s %-35s %-12s %-14s %-10s %s' "$op" "$repo" "$version" "$commit" "$status" "$url"
    else
        printf '%-8s %-35s %-12s %-14s %s' "$op" "$repo" "$version" "$commit" "$status"
    fi
}

main() {
    parse_args "$@"

    for short in "${!OP_REPO[@]}"; do
        REPO_TO_SHORT[${OP_REPO[$short]}]="$short"
    done

    validate_prerequisites
    find_fbc_prod_release

    extract_bundles_from_fbc

    local -a summary=()
    local -a tagged=() skipped=() failed=()

    for i in "${!BUNDLE_NAMES[@]}"; do
        local bundle_name="${BUNDLE_NAMES[$i]}"
        local bundle_image="${BUNDLE_IMAGES[$i]}"
        local operator="${bundle_name%%.*}"
        local version="${bundle_name#*.v}"
        local major="${version%%.*}"
        local rest="${version#*.}"
        local minor="${rest%%.*}"

        local op_short="${REPO_TO_SHORT[$operator]:-}"
        if [[ -z "$op_short" ]]; then
            warn "Unknown operator: ${operator} — skipping"
            continue
        fi

        local repo="${OP_REPO[$op_short]}"
        log "Processing ${operator} v${version} (${op_short})"

        local commit
        if ! commit=$(resolve_bundle_to_commit "$op_short" "$bundle_image" "$major" "$minor"); then
            summary+=("$(summary_line "$op_short" "$repo" "v${version}" "—" "FAILED")")
            failed+=("$op_short")
            continue
        fi

        local short_commit="${commit:0:12}"
        local url
        url=$(commit_url "$repo" "$commit")

        if [[ "$COMMITS_ONLY" == true ]]; then
            local tag_status
            tag_status=$(verify_existing_tag "$repo" "$version" "$commit")
            case "$tag_status" in
                "OK (tag matches)")
                    summary+=("$(summary_line "$op_short" "$repo" "v${version}" "$short_commit" "OK" "$url")")
                    skipped+=("$op_short")
                    ;;
                "NEEDS TAG")
                    summary+=("$(summary_line "$op_short" "$repo" "v${version}" "$short_commit" "NEEDS TAG" "$url")")
                    tagged+=("$op_short")
                    ;;
                MISMATCH*)
                    local existing_commit="${tag_status#MISMATCH }"
                    summary+=("$(summary_line "$op_short" "$repo" "v${version}" "$short_commit" "MISMATCH" "$url")")
                    failed+=("$op_short")
                    ;;
            esac
            continue
        fi

        local display
        display=$(display_name "$repo")
        local result
        result=$(tag_downstream_repo "$repo" "$version" "$commit" "$display")
        case "$result" in
            created)
                summary+=("$(summary_line "$op_short" "$repo" "v${version}" "$short_commit" "CREATED" "$url")")
                tagged+=("$op_short")
                ;;
            exists)
                summary+=("$(summary_line "$op_short" "$repo" "v${version}" "$short_commit" "OK" "$url")")
                skipped+=("$op_short")
                ;;
            skipped)
                summary+=("$(summary_line "$op_short" "$repo" "v${version}" "—" "SKIPPED")")
                skipped+=("$op_short")
                ;;
            *)
                summary+=("$(summary_line "$op_short" "$repo" "v${version}" "$short_commit" "FAILED" "$url")")
                failed+=("$op_short")
                ;;
        esac
    done

    echo ""
    log "Summary"
    echo ""
    printf "    %-8s %-35s %-12s %-14s %-10s %s\n" "OP" "REPO" "VERSION" "COMMIT" "STATUS" "URL"
    printf "    %-8s %-35s %-12s %-14s %-10s %s\n" "──" "────" "───────" "──────" "──────" "───"
    for entry in "${summary[@]}"; do
        printf "    %s\n" "$entry"
    done
    echo ""

    [[ ${#tagged[@]} -eq 0 ]]  || info "Tagged: ${tagged[*]}"
    [[ ${#skipped[@]} -eq 0 ]] || info "Skipped (already existed): ${skipped[*]}"
    [[ ${#failed[@]} -eq 0 ]]  || warn "Failed: ${failed[*]}"

    log "Done."
}

main "$@"
