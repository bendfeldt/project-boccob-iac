#!/usr/bin/env bash
# cosign verification driven by scripts/supply-chain/signature-policy.yaml.
#   scripts/supply-chain/verify-signatures.sh <env> [image-key ...]
#
# Policy entry per image key (see signature-policy.yaml):
#   mode: keyless   -> cosign verify --certificate-identity-regexp/--certificate-oidc-issuer
#                      against the UPSTREAM reference (needs internet: run before mirroring)
#   mode: key       -> cosign verify --key <file> against the Zot copy (own artefacts,
#                      e.g. images published by the solution repo; works air-gapped)
#   mode: none      -> not signed upstream / not verifiable: reported, never silently skipped
# REQUIRE_ALL=1 turns "none" into a failure.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"; shift || true
require_cmd cosign yq jq
policy="$(yq -c . "${REPO_ROOT}/scripts/supply-chain/signature-policy.yaml")"
keys=("$@"); if [[ ${#keys[@]} -eq 0 ]]; then mapfile -t keys < <(lock_keys images "${MIRROR_GROUPS:-}"); fi
rc=0
for key in "${keys[@]}"; do
  entry="$(jq -c --arg k "$key" '.images[$k] // .default' <<<"$policy")"
  mode="$(jq -r '.mode' <<<"$entry")"
  case "$mode" in
    keyless)
      src="$(lock_q '.images[$k].source' --arg k "$key")"
      # upstream signatures are made over the index (multi-arch) digest
      digest="$(lock_q '.images[$k].index_digest // ""' --arg k "$key")"
      [[ -n "$digest" ]] || digest="$(image_digest "$key")"
      if cosign verify "${src}@${digest}" \
           --certificate-identity-regexp "$(jq -r '.identity_regexp' <<<"$entry")" \
           --certificate-oidc-issuer "$(jq -r '.oidc_issuer' <<<"$entry")" >/dev/null 2>"${TMPDIR:-/tmp}/cosign.err"; then
        log "verified (keyless): ${key}"
      else
        err "signature verification FAILED: ${key}: $(tail -n 1 "${TMPDIR:-/tmp}/cosign.err" | cut -c1-300)"; rc=1
      fi ;;
    key)
      if cosign verify --insecure-ignore-tlog=true --key "$(jq -r '.key' <<<"$entry")" "$(image_zot_digest_ref "$key")" >/dev/null 2>&1; then
        log "verified (key): ${key}"
      else
        err "signature verification FAILED: ${key}"; rc=1
      fi ;;
    none)
      warn "no signature policy for ${key} (mode: none)"
      [[ "${REQUIRE_ALL:-0}" == "1" ]] && rc=1 ;;
    *) err "unknown mode '${mode}' for ${key}"; rc=1 ;;
  esac
done
exit $rc
