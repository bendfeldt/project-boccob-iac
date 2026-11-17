#!/usr/bin/env bash
# Trivy vulnerability databases for the air gap (OCI artefacts, ~150 MB + ~800 MB java DB).
#
#   scripts/supply-chain/trivy-db.sh sync   <env>          connected: upstream -> Zot
#   scripts/supply-chain/trivy-db.sh bundle <env> <dir>    connected: upstream -> <dir>/trivy-db (OCI layout)
#   scripts/supply-chain/trivy-db.sh load   <env> <dir>    air-gapped: <dir>/trivy-db -> Zot
#
# Zot locations (used by scan.sh automatically when present):
#   <registry>/ghcr.io/aquasecurity/trivy-db:2      (TRIVY_DB_SOURCE)
#   <registry>/ghcr.io/aquasecurity/trivy-java-db:1 (TRIVY_JAVA_DB_SOURCE, only with JAVA_DB=1)
# The DB is rebuilt upstream every few hours: re-sync/re-bundle regularly
# (e.g. with every patch cycle) and record the DB timestamp in the scan report.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
cmd="${1:-}"; shift || true
load_env "${1:-${ENV:-}}"; shift || true
require_cmd skopeo
TRIVY_DB_SOURCE="${TRIVY_DB_SOURCE:-ghcr.io/aquasecurity/trivy-db:2}"
TRIVY_JAVA_DB_SOURCE="${TRIVY_JAVA_DB_SOURCE:-ghcr.io/aquasecurity/trivy-java-db:1}"
sources=("$TRIVY_DB_SOURCE")
[[ "${JAVA_DB:-0}" == "1" ]] && sources+=("$TRIVY_JAVA_DB_SOURCE")

copy() { skopeo copy --quiet --preserve-digests --authfile "$REGISTRY_AUTH_FILE" "$1" "$2"; }

case "$cmd" in
  sync)
    registry_login
    for s in "${sources[@]}"; do
      log "sync ${s} -> ${REGISTRY_HOST}/${s}"
      copy "docker://${s}" "docker://${REGISTRY_HOST}/${s}"
    done ;;
  bundle)
    dir="${1:?bundle dir required}"; mkdir -p "${dir}/trivy-db"
    for s in "${sources[@]}"; do
      log "bundle ${s}"
      copy "docker://${s}" "oci:${dir}/trivy-db:${s//[\/:]/_}"
    done ;;
  load)
    dir="${1:?bundle dir required}"; registry_login
    for s in "${sources[@]}"; do
      log "load ${s} -> ${REGISTRY_HOST}/${s}"
      copy "oci:${dir}/trivy-db:${s//[\/:]/_}" "docker://${REGISTRY_HOST}/${s}"
    done ;;
  *) die "usage: trivy-db.sh sync|bundle|load <env> [dir]" ;;
esac
