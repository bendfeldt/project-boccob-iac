#!/usr/bin/env bash
# cosign signatures for the solution artefacts with the platform signing key.
# The key is an OpenBao transit key (ecdsa-p256, not exportable) created by
# stack 31-policy; the private key never leaves OpenBao. Kyverno verifies the
# signatures at admission with the public key (policy
# verify-solution-image-signatures).
#
#   scripts/supply-chain/sign.sh <env> sign   <image@sha256:...> [...]   sign artefacts in Zot
#   scripts/supply-chain/sign.sh <env> verify <image@sha256:...> [...]   verify (no OpenBao access needed with COSIGN_PUBLIC_KEY=<file>)
#   scripts/supply-chain/sign.sh <env> public-key                        print the PEM public key
#
# References must carry a digest (a tag can move). No transparency log is
# used: the platform is air-gapped, trust is anchored in the OpenBao key.
# OpenBao token: dev = root token of the init file; otherwise BAO_TOKEN of a
# person/job holding the policy `cosign-signer`.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/openbao.sh
source "${REPO_ROOT}/scripts/lib/openbao.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
load_env "${1:-${ENV:-}}"; shift || true
action="${1:-}"; shift || true
require_cmd cosign jq

COSIGN_KEY_NAME="${COSIGN_KEY_NAME:-cosign-solution}"
export TRANSIT_SECRET_ENGINE_PATH="${TRANSIT_SECRET_ENGINE_PATH:-transit}"
export COSIGN_YES=true

openbao_session() {
  openbao_port_forward_start
  trap openbao_port_forward_stop EXIT
  openbao_export_token
  export VAULT_ADDR VAULT_CACERT VAULT_TLS_SERVER_NAME VAULT_TOKEN
}

# cosign reads registry credentials from a docker config directory
registry_session() {
  registry_login
  DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG
  install -m 0600 "$REGISTRY_AUTH_FILE" "${DOCKER_CONFIG}/config.json"
}

need_digest() { [[ "$1" == *@sha256:* ]] || die "reference without digest: $1"; }

case "$action" in
  sign)
    [[ $# -gt 0 ]] || die "usage: sign.sh <env> sign <image@sha256:...> [...]"
    openbao_session; registry_session
    # a signing config without Fulcio/Rekor/TSA services: nothing leaves the site
    signing_config="${DOCKER_CONFIG}/signing-config.json"
    cosign signing-config create --out "$signing_config" >/dev/null
    for ref in "$@"; do
      need_digest "$ref"
      cosign sign --key "hashivault://${COSIGN_KEY_NAME}" --signing-config "$signing_config" "$ref" >/dev/null
      log "signed ${ref}"
    done
    rm -rf "$DOCKER_CONFIG" ;;
  verify)
    [[ $# -gt 0 ]] || die "usage: sign.sh <env> verify <image@sha256:...> [...]"
    if [[ -n "${COSIGN_PUBLIC_KEY:-}" ]]; then key="$COSIGN_PUBLIC_KEY"; else openbao_session; key="hashivault://${COSIGN_KEY_NAME}"; fi
    rc=0
    for ref in "$@"; do
      need_digest "$ref"
      if out="$(cosign verify --key "$key" --insecure-ignore-tlog=true "$ref" 2>&1 >/dev/null)"; then
        log "verified ${ref}"
      else
        err "NOT verified ${ref}: $(tail -n 1 <<<"$out" | cut -c1-200)"; rc=1
      fi
    done
    exit $rc ;;
  public-key)
    openbao_session
    cosign public-key --key "hashivault://${COSIGN_KEY_NAME}" ;;
  *) die "usage: sign.sh <env> sign|verify|public-key [image@sha256:...]" ;;
esac
