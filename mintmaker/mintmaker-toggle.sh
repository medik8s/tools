#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/mintmaker-config.yaml"
DRY_RUN=false
NAMESPACE="rhwa-tenant"
ANNOTATION="mintmaker.appstudio.redhat.com/disabled"

log()  { echo -e "\n=== $* ==="; }
info() { echo "  -> $*"; }
warn() { echo "  !! $*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [-n|--dry-run] [-c|--config FILE]

Toggle Mintmaker (Renovate) on Konflux components via annotation.

Options:
  -n, --dry-run       Print actions without executing
  -c, --config FILE   Config file (default: mintmaker-config.yaml in script dir)
  -h, --help          Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true; shift ;;
    -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)            warn "Unknown option: $1"; usage ;;
  esac
done

command -v yq >/dev/null 2>&1 || { warn "yq not found (brew install yq)"; exit 1; }
command -v oc >/dev/null 2>&1 || { warn "oc not found"; exit 1; }

[[ -f "$CONFIG_FILE" ]] || { warn "Config not found: ${CONFIG_FILE}"; exit 1; }

get_components() {
  local op="$1" ver="$2"
  echo "${op}-operator-${ver}"
  echo "${op}-bundle-${ver}"
  case "$op" in
    nhc)
      echo "nhc-console-${ver}"
      echo "nhc-must-gather-${ver}"
      ;;
    sbr)
      echo "sbr-agent-${ver}"
      ;;
  esac
}

failures=0
total=0

for op in $(yq 'keys | .[]' "$CONFIG_FILE"); do
  for ver in $(yq ".\"${op}\" | keys | .[]" "$CONFIG_FILE"); do
    enabled=$(yq ".\"${op}\".\"${ver}\"" "$CONFIG_FILE")
    log "${op} / ${ver}"

    mapfile -t components < <(get_components "$op" "$ver")

    for component in "${components[@]}"; do
      total=$((total + 1))

      if [[ "$enabled" == "true" ]]; then
        info "ENABLE mintmaker: ${component}"
        if [[ "$DRY_RUN" == "false" ]]; then
          if ! oc -n "$NAMESPACE" annotate "component/${component}" "${ANNOTATION}-" --overwrite 2>/dev/null; then
            true
          fi
        fi
      else
        info "DISABLE mintmaker: ${component}"
        if [[ "$DRY_RUN" == "false" ]]; then
          if ! oc -n "$NAMESPACE" annotate "component/${component}" "${ANNOTATION}=true" --overwrite; then
            warn "Failed: ${component}"
            failures=$((failures + 1))
          fi
        fi
      fi
    done
  done
done

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  info "[DRY-RUN] ${total} components would be updated"
else
  info "${total} components processed, ${failures} failures"
fi

[[ "$failures" -eq 0 ]]
