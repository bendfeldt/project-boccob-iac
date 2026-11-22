#!/usr/bin/env bash
# macOS only: trust the dev CAs in the System keychain.
#   macos-trust.sh <env> add|remove|check
#
# Go programs on macOS (skopeo, helm, tofu, kubectl plugins, cosign, oras, crane)
# verify TLS against the macOS keychain and ignore SSL_CERT_FILE, so the registry
# CA (${STATE_DIR}/pki/registry-ca.crt) must be trusted there before mirroring.
# Browsers (Safari, Chrome) also need the platform root CA (from
# ${STATE_DIR}/pki/platform-ca.crt, written by make dev-env) for the web UIs. Only the
# ROOT is trusted: the issuing CA chains to it, and the cert-manager bootstrap CA
# (OpenBao's listener only) must never be a trusted root on the Mac. Both CAs carry
# name constraints (registry CA: the dev names; root: the platform's domains), so
# they cannot vouch for an outside site. Firefox has its own store.
# `add` and `remove` use sudo (System keychain); `check` needs no privileges.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
action="${2:-check}"
[[ "$(host_os)" == "darwin" ]] || { log "not macOS: nothing to do (Linux uses SSL_CERT_FILE / the browser's own import)"; exit 0; }
require_cmd security openssl
keychain="/Library/Keychains/System.keychain"

cas=("${STATE_DIR}/pki/registry-ca.crt")
[[ -f "${STATE_DIR}/pki/platform-ca.crt" ]] && cas+=("${STATE_DIR}/pki/platform-ca.crt")

# trusted <pem>: the certificate (by SHA-1, as `security` prints it) is in the System keychain
trusted() {
  local sha1
  sha1="$(openssl x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
  security find-certificate -a -Z "$keychain" 2>/dev/null | grep -qi "SHA-1 hash: ${sha1}"
}

rc=0
for ca in "${cas[@]}"; do
  [[ -f "$ca" ]] || { warn "missing ${ca} (run make cluster-up first)"; rc=1; continue; }
  # platform-ca.crt is a bundle (root + issuing + bootstrap CA): only its root counts
  tmpd="$(mktemp -d)"
  awk -v d="$tmpd" '/BEGIN CERTIFICATE/{n++} n{print > (d "/" n ".pem")}' "$ca"
  for pem in "$tmpd"/*.pem; do
    subject="$(openssl x509 -in "$pem" -noout -subject | sed 's/^subject= *//')"
    [[ "$action" != remove && "$ca" == *platform-ca.crt && "$subject" != *"Root CA"* ]] && continue
    case "$action" in
      check)
        if trusted "$pem"; then log "trusted: ${subject}"; else warn "NOT trusted: ${subject}"; rc=1; fi ;;
      add)
        if trusted "$pem"; then log "already trusted: ${subject}"; else
          log "trusting ${subject} (sudo)"
          sudo security add-trusted-cert -d -r trustRoot -k "$keychain" "$pem" || rc=1
        fi ;;
      remove)
        if trusted "$pem"; then
          log "removing ${subject} (sudo)"
          sudo security remove-trusted-cert -d "$pem" || true
          sha1="$(openssl x509 -in "$pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
          sudo security delete-certificate -Z "$sha1" "$keychain" || rc=1
        fi ;;
      *) die "usage: macos-trust.sh <env> add|remove|check" ;;
    esac
  done
  rm -rf "$tmpd"
done
exit $rc
