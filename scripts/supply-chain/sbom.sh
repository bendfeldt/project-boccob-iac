#!/usr/bin/env bash
# SBOM (SPDX JSON, syft) for mirrored images, straight from Zot.
#   scripts/supply-chain/sbom.sh <env> [image-key ...]
# Output: ${REPORT_DIR:-${BOCCOB_CACHE_DIR}/reports/<env>}/sbom/<key>.spdx.json
#   ATTEST=1  additionally attach the SBOM to the image in Zot as a cosign
#             attestation (needs COSIGN_KEY, see verify-signatures.sh)
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"; shift || true
require_cmd syft
out="${REPORT_DIR:-${BOCCOB_CACHE_DIR}/reports/${ENV}}/sbom"; mkdir -p "$out"
keys=("$@"); if [[ ${#keys[@]} -eq 0 ]]; then mapfile -t keys < <(lock_keys images "${MIRROR_GROUPS:-}"); fi
for key in "${keys[@]}"; do
  ref="$(image_zot_digest_ref "$key")"
  syft scan -q "registry:${ref}" -o "spdx-json=${out}/${key}.spdx.json"
  log "sbom ${key}: $(jq '.packages | length' "${out}/${key}.spdx.json") packages"
  if [[ "${ATTEST:-0}" == "1" ]]; then
    require_cmd cosign
    : "${COSIGN_KEY:?COSIGN_KEY (private key reference) is required for ATTEST=1}"
    cosign attest --yes --tlog-upload=false --key "$COSIGN_KEY" --type spdxjson \
      --predicate "${out}/${key}.spdx.json" "$ref"
  fi
done
