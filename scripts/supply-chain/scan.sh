#!/usr/bin/env bash
# Vulnerability scan (Trivy) of mirrored images, straight from Zot.
#   scripts/supply-chain/scan.sh <env> [image-key ...]     default: every locked image
# Reports: ${REPORT_DIR:-${BOCCOB_CACHE_DIR}/reports/<env>}/trivy/<key>.json
#   FAIL_ON=CRITICAL        exit 1 when a finding of this severity (comma list) exists
#   TRIVY_DB_REPOSITORY     vulnerability DB as OCI artefact (air-gap: mirror
#                           ghcr.io/aquasecurity/trivy-db into Zot and point here)
#   TRIVY_SKIP_DB_UPDATE=1  use the DB already in the trivy cache
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"; shift || true
require_cmd trivy jq
out="${REPORT_DIR:-${BOCCOB_CACHE_DIR}/reports/${ENV}}/trivy"; mkdir -p "$out"
keys=("$@"); if [[ ${#keys[@]} -eq 0 ]]; then mapfile -t keys < <(lock_keys images "${MIRROR_GROUPS:-}"); fi
args=(image --quiet --format json --scanners vuln --cache-dir "${BOCCOB_CACHE_DIR}/trivy")
[[ "${TRIVY_SKIP_DB_UPDATE:-0}" == "1" ]] && args+=(--skip-db-update)
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
