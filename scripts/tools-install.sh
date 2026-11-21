#!/usr/bin/env bash
# Install the pinned supply-chain tools (cosign, trivy, syft, oras) from
# versions.lock.yaml into ${BOCCOB_CACHE_DIR}/bin (checksum verified).
#   BUNDLE_DIR=<airgap bundle>  take the files from the bundle instead of the internet
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd curl tar sha256sum jq yq
bin="${BOCCOB_CACHE_DIR}/bin"; mkdir -p "$bin"
while read -r key; do
  file="$(lock_q '.binaries[$k].file' --arg k "$key")"
  sum="$(lock_q '.binaries[$k].sha256' --arg k "$key")"
  extract="$(lock_q '.binaries[$k].extract // ""' --arg k "$key")"
  src="${BOCCOB_CACHE_DIR}/downloads/${key}/${file}"
  if [[ -n "${BUNDLE_DIR:-}" && -f "${BUNDLE_DIR}/binaries/${file}" ]]; then
    src="${BUNDLE_DIR}/binaries/${file}"
    [[ "$(sha256_of "$src")" == "$sum" ]] || die "checksum mismatch: ${src}"
  else
    fetch_verified "$(lock_q '.binaries[$k].url' --arg k "$key")" "$src" "$sum"
  fi
  if [[ -n "$extract" ]]; then
    tar -xzf "$src" -C "$bin" "$extract"
  else
    install -m 0755 "$src" "${bin}/${key}"
  fi
  chmod 0755 "${bin}/${extract:-$key}"
  log "installed ${key} -> ${bin}/${extract:-$key}"
done < <(lock_keys binaries tools)
