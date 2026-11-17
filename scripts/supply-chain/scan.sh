#!/usr/bin/env bash
# Vulnerability scan (Trivy) of mirrored images, straight from Zot.
#   scripts/supply-chain/scan.sh <env> [image-key ...]     default: every locked image
# Reports: ${REPORT_DIR:-${BOCCOB_CACHE_DIR}/reports/<env>}/trivy/<key>.json
#   FAIL_ON=CRITICAL        exit 1 when a finding of this severity (comma list) exists
#   TRIVY_DB_REPOSITORY     vulnerability DB as OCI artefact. Default: the Zot copy
#                           <registry>/ghcr.io/aquasecurity/trivy-db:2 when present
#                           (make trivy-db), else trivy's upstream default
#   TRIVY_SKIP_DB_UPDATE=1  use the DB already in the trivy cache
#   TRIVY_OFFLINE=1         no network for trivy at all: cached DB, no Java DB
#                           update, --offline-scan (air-gapped workstation)
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
load_env "${1:-${ENV:-}}"; shift || true
require_cmd trivy jq
out="${REPORT_DIR:-${BOCCOB_CACHE_DIR}/reports/${ENV}}/trivy"; mkdir -p "$out"
keys=("$@"); if [[ ${#keys[@]} -eq 0 ]]; then mapfile -t keys < <(lock_keys images "${MIRROR_GROUPS:-}"); fi
args=(image --quiet --format json --scanners vuln --cache-dir "${BOCCOB_CACHE_DIR}/trivy")
if [[ "${TRIVY_OFFLINE:-0}" == "1" ]]; then
  args+=(--skip-db-update --skip-java-db-update --offline-scan)
else
  [[ "${TRIVY_SKIP_DB_UPDATE:-0}" == "1" ]] && args+=(--skip-db-update)
  if [[ -z "${TRIVY_DB_REPOSITORY:-}" ]] && registry_has_manifest "ghcr.io/aquasecurity/trivy-db" 2 2>/dev/null; then
    TRIVY_DB_REPOSITORY="${REGISTRY_HOST}/ghcr.io/aquasecurity/trivy-db:2"
  fi
  if [[ -n "${TRIVY_DB_REPOSITORY:-}" ]]; then
    log "vulnerability DB from ${TRIVY_DB_REPOSITORY}"
    args+=(--db-repository "$TRIVY_DB_REPOSITORY")
  fi
fi
rc=0
for key in "${keys[@]}"; do
  ref="$(image_zot_digest_ref "$key")"
  if ! trivy "${args[@]}" --output "${out}/${key}.json" "$ref"; then err "trivy failed for ${key}"; rc=1; continue; fi
  summary="$(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "${out}/${key}.json")"
  log "${key}: ${summary:-no findings}"
  if [[ -n "${FAIL_ON:-}" ]] && jq -e --arg s "$FAIL_ON" '[.Results[]?.Vulnerabilities[]?.Severity] | any(. as $x | ($s | split(",")) | index($x))' "${out}/${key}.json" >/dev/null; then
    err "${key}: findings with severity ${FAIL_ON}"; rc=1
  fi
done
exit $rc
