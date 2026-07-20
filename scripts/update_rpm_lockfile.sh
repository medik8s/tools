#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: update_rpm_lockfile.sh --containerfile <FILE> --base-image <IMAGE> [OPTIONS]

Generate or regenerate rpms.lock.yaml for hermetic Konflux builds.
Runs rpm-lockfile-prototype inside a UBI container via podman.

Required:
  --containerfile <FILE>    Containerfile to resolve RPMs for
  --base-image <IMAGE>      UBI base image with tag (e.g., registry.access.redhat.com/ubi9/ubi-minimal:9.6-1755695350)

Options:
  --rpms-in <FILE>          Input file (default: rpms.in.yaml)
  --output <FILE>           Output lockfile path (default: rpms.lock.yaml)
  --lockfile-version <TAG>  rpm-lockfile-prototype version (default: v0.21.0)
  --fix-ssl                 Replace SSL cert/key paths in redhat.repo with MintMaker variables
  --dry-run                 Print the podman command without executing
  -h, --help                Show this help

Environment:
  ACTIVATION_KEY   (required) Red Hat activation key for subscription-manager
  ORG_ID           (required) Red Hat organization ID for subscription-manager
  REGISTRY_USER    (required) Username for registry.redhat.io (skopeo login)
  REGISTRY_PASSWORD (required) Password for registry.redhat.io (skopeo login)

Run from the operator repo root (where Containerfile and rpms.in.yaml live).

Example:
  cd /path/to/fence-agents-remediation
  export ACTIVATION_KEY="my-key" ORG_ID="12345"
  export REGISTRY_USER="user" REGISTRY_PASSWORD="pass"
  /path/to/tools/scripts/update_rpm_lockfile.sh \
    --containerfile Containerfile.fence-agents-remediation \
    --base-image registry.access.redhat.com/ubi9/ubi-minimal:9.6-1755695350 \
    --fix-ssl

See scripts/docs/rpm_lockfile_update.md for background and multi-arch instructions.
EOF
}

containerfile=""
base_image=""
rpms_in="rpms.in.yaml"
output="rpms.lock.yaml"
lockfile_version="v0.21.0"
fix_ssl=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --containerfile)  containerfile="$2"; shift 2 ;;
    --base-image)     base_image="$2"; shift 2 ;;
    --rpms-in)        rpms_in="$2"; shift 2 ;;
    --output)         output="$2"; shift 2 ;;
    --lockfile-version) lockfile_version="$2"; shift 2 ;;
    --fix-ssl)        fix_ssl=true; shift ;;
    --dry-run)        dry_run=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$containerfile" || -z "$base_image" ]]; then
  echo "Error: --containerfile and --base-image are required." >&2
  usage >&2
  exit 1
fi

for var in ACTIVATION_KEY ORG_ID REGISTRY_USER REGISTRY_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: ${var} environment variable is required." >&2
    exit 1
  fi
done

if [[ ! -f "$containerfile" ]]; then
  echo "Error: Containerfile not found: ${containerfile}" >&2
  exit 1
fi
if [[ ! -f "$rpms_in" ]]; then
  echo "Error: RPM input file not found: ${rpms_in}" >&2
  exit 1
fi

lockfile_url="https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/tags/${lockfile_version}.tar.gz"

podman_cmd=(
  podman run --rm
  -v "$(pwd):/source:Z"
  -e "ACTIVATION_KEY=${ACTIVATION_KEY}"
  -e "ORG_ID=${ORG_ID}"
  -e "REGISTRY_USER=${REGISTRY_USER}"
  -e "REGISTRY_PASSWORD=${REGISTRY_PASSWORD}"
  -e "CONTAINERFILE=${containerfile}"
  -e "RPMS_IN=${rpms_in}"
  -e "LOCKFILE_URL=${lockfile_url}"
  "$base_image"
  /bin/bash -c '
set -euo pipefail
echo "==> Installing tools..."
microdnf install -y subscription-manager pip skopeo python3-dnf >/dev/null 2>&1
pip install --user "${LOCKFILE_URL}" >/dev/null 2>&1
export PATH="${HOME}/.local/bin:${PATH}"

echo "==> Registering with subscription-manager..."
subscription-manager register --activationkey="${ACTIVATION_KEY}" --org="${ORG_ID}"

echo "==> Copying redhat.repo and substituting arch..."
cp /etc/yum.repos.d/redhat.repo /source/redhat.repo
sed -i "s/$(uname -m)/\$basearch/g" /source/redhat.repo

echo "==> Logging into registry.redhat.io..."
skopeo login -u "${REGISTRY_USER}" -p "${REGISTRY_PASSWORD}" registry.redhat.io

echo "==> Generating lockfile..."
cd /source
rpm-lockfile-prototype -f "${CONTAINERFILE}" "${RPMS_IN}"
echo "==> Done."
'
)

if [[ "$dry_run" == true ]]; then
  echo "Would run:"
  printf '%q ' "${podman_cmd[@]}"
  echo
  exit 0
fi

echo "Generating ${output} using ${base_image}..."
"${podman_cmd[@]}"

if [[ "$output" != "rpms.lock.yaml" ]] && [[ -f "rpms.lock.yaml" ]]; then
  mv rpms.lock.yaml "$output"
fi

if [[ "$fix_ssl" == true ]] && [[ -f "redhat.repo" ]]; then
  echo "Fixing SSL cert/key paths in redhat.repo for MintMaker..."
  sed -i 's|sslclientcert=/etc/pki/entitlement-host/.*\.pem|sslclientcert=$SSL_CLIENT_CERT|' redhat.repo
  sed -i 's|sslclientkey=/etc/pki/entitlement-host/.*-key\.pem|sslclientkey=$SSL_CLIENT_KEY|' redhat.repo
fi

echo "Generated: ${output}"
if [[ -f "redhat.repo" ]]; then
  echo "Updated:   redhat.repo"
fi
