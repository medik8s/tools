#!/usr/bin/env bash
# Shared helpers for RHWA helper_scripts (catalog wait, pull-secret merge, ClusterCatalog).
# Sourced by install_rhwa_operators.sh and sync_clustercatalog_from_catalogsource.sh — do not execute directly.

[[ -n "${_RHWA_UTILS_SOURCED:-}" ]] && return 0
_RHWA_UTILS_SOURCED=1

rhwa_wait_catsrc_ready() {
  local catsrc="$1" catsrc_ns="$2" timeout_s="$3"
  echo "Waiting for CatalogSource ${catsrc} to be READY (${timeout_s}s)..."
  if ! oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
    "catalogsource/${catsrc}" -n "${catsrc_ns}" --timeout="${timeout_s}s" 2>/dev/null; then
    local state
    state=$(oc get "catalogsource/${catsrc}" -n "${catsrc_ns}" \
      -o jsonpath='{.status.connectionState.lastObservedState}{" "}{.status.connectionState.message}{"\n"}' 2>/dev/null || echo "unknown")
    echo "Error: CatalogSource not READY: ${state}" >&2
    return 1
  fi
}

rhwa_merge_secret_file_into_global() {
  local secret_file="$1" label="${2:-secret file}"

  command -v jq >/dev/null || {
    echo "Error: jq required to merge pull secrets into global pull-secret" >&2
    return 1
  }

  if ! oc get secret pull-secret -n openshift-config &>/dev/null; then
    echo "Error: openshift-config/pull-secret not found" >&2
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir:-}"' RETURN

  oc extract secret/pull-secret -n openshift-config --to="$tmpdir" --confirm >/dev/null 2>&1 \
    || return 1

  local before after
  before=$(jq -r '.auths | keys | length' "$tmpdir/.dockerconfigjson")
  jq -s '
    (.[0].auths) as $existing |
    (.[1].auths) as $incoming |
    $existing + ($incoming | with_entries(select(.key as $k | ($existing | has($k)) | not)))
    | {auths: .}
  ' "$tmpdir/.dockerconfigjson" "$secret_file" > "$tmpdir/merged.json"
  after=$(jq -r '.auths | keys | length' "$tmpdir/merged.json")

  if [[ "$after" -le "$before" ]]; then
    echo "Global pull-secret already includes registries from ${label}."
    return 0
  fi

  echo "Merging ${label} into global pull-secret (+$((after - before)) registry entries)."
  local backup_path="${HOME}/pull-secret-backup-$(date +%s).yaml"
  local -a old_backups=()
  (umask 077; oc get secret pull-secret -n openshift-config -o yaml > "$backup_path")
  mapfile -t old_backups < <(ls -1t "${HOME}"/pull-secret-backup-*.yaml 2>/dev/null || true)
  local _i
  for ((_i = 3; _i < ${#old_backups[@]}; _i++)); do
    rm -f "${old_backups[_i]}"
  done
  echo "Backup saved to ${backup_path} (mode 600). Restore with: oc apply -f ${backup_path}"
  if ! oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson="$tmpdir/merged.json" >/dev/null; then
    echo "Error: failed to update pull-secret; restoring from backup..." >&2
    if ! oc apply -f "$backup_path" >/dev/null 2>&1; then
      echo "Error: restore failed — manually restore: oc apply -f ${backup_path}" >&2
    fi
    return 1
  fi
  echo "Updated openshift-config/pull-secret."
  if oc get deployment catalogd-controller-manager -n openshift-catalogd &>/dev/null; then
    oc rollout restart deployment/catalogd-controller-manager -n openshift-catalogd >/dev/null
    echo "Restarted catalogd deployment to pick up pull credentials."
  fi
  return 0
}

rhwa_merge_catsrc_pull_secrets_into_global() {
  local catsrc="$1" catsrc_ns="$2"
  local -a secrets=()
  local sec

  while IFS= read -r sec; do
    [[ -n "$sec" ]] && secrets+=("$sec")
  done < <(oc get catalogsource "$catsrc" -n "$catsrc_ns" \
    -o jsonpath='{range .spec.secrets[*]}{.}{"\n"}{end}' 2>/dev/null || true)

  if [[ ${#secrets[@]} -eq 0 ]]; then
    echo "CatalogSource ${catsrc} has no spec.secrets; skipping global pull-secret merge."
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir:-}"' RETURN

  for sec in "${secrets[@]}"; do
    if ! oc get secret "$sec" -n "$catsrc_ns" &>/dev/null; then
      echo "Warning: CatalogSource secret ${sec} not found in ${catsrc_ns}; skipping." >&2
      continue
    fi
    oc get secret "$sec" -n "$catsrc_ns" -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
      > "$tmpdir/${sec}.json"
    rhwa_merge_secret_file_into_global "$tmpdir/${sec}.json" "${sec} (${catsrc_ns})"
  done
}

rhwa_wait_clustercatalog_serving() {
  local cc="$1" timeout_s="$2"
  echo "Waiting for ClusterCatalog ${cc} to be Serving (${timeout_s}s)..."
  local deadline msg
  deadline=$(( $(date +%s) + timeout_s ))
  while (( $(date +%s) < deadline )); do
    if oc get "clustercatalog/${cc}" -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" "}{end}' 2>/dev/null \
      | grep -q 'Serving=True'; then
      echo "ClusterCatalog ${cc} is Serving."
      return 0
    fi
    msg=$(oc get "clustercatalog/${cc}" -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.message}{end}' 2>/dev/null || true)
    [[ -n "$msg" ]] && echo "  Progressing: $msg"
    sleep 10
  done
  echo "Error: timeout waiting for ClusterCatalog ${cc} to serve" >&2
  oc describe "clustercatalog/${cc}" 2>/dev/null | tail -25 >&2 || true
  return 1
}
