#!/usr/bin/env bash
# Install the pinned operator tools (tofu, helm, cosign, trivy, syft, oras) from
# versions.lock.yaml into ${BOCCOB_CACHE_DIR}/bin (checksum verified), in the
# build for THIS machine: linux/amd64 (x64), linux/arm64 or darwin/arm64
# (Apple Silicon). Other platforms fail with a clear message.
#   BUNDLE_DIR=<airgap bundle>  take the files from the bundle instead of the internet
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd curl tar jq yq
bin="${BOCCOB_CACHE_DIR}/bin"; mkdir -p "$bin"
platform="$(host_platform)"
log "platform: ${platform}"
while read -r key; do
  p="$(binary_platform "$key" "$platform")"
  file="$(binary_field "$key" "$p" file)"
  sum="$(binary_field "$key" "$p" sha256)"
  extract="$(lock_q '.binaries[$k].extract // ""' --arg k "$key")"
  src="${BOCCOB_CACHE_DIR}/downloads/${key}/${file}"
  if [[ -n "${BUNDLE_DIR:-}" && -f "${BUNDLE_DIR}/binaries/${file}" ]]; then
    src="${BUNDLE_DIR}/binaries/${file}"
    [[ "$(sha256_of "$src")" == "$sum" ]] || die "checksum mismatch: ${src}"
  else
    fetch_verified "$(binary_field "$key" "$p" url)" "$src" "$sum"
  fi
  if [[ -n "$extract" ]]; then
    # path inside the tarball; {os}-{arch} = this platform (helm: linux-amd64/helm)
    extract="${extract//\{os\}-\{arch\}/${p/\//-}}"
    tmp="$(mktemp -d)"
    tar -xzf "$src" -C "$tmp" "$extract"
    install -m 0755 "${tmp}/${extract}" "${bin}/${key}"
    rm -rf "$tmp"
  else
    install -m 0755 "$src" "${bin}/${key}"
  fi
  log "installed ${key} (${p}) -> ${bin}/${key}"
done < <(lock_keys binaries tools)
