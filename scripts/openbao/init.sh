#!/usr/bin/env bash
# Initialise (once) and unseal OpenBao; let the remaining raft members join.
#
#   scripts/openbao/init.sh <env>              init if needed, then unseal every member
#   scripts/openbao/init.sh <env> --unseal     only unseal (after a pod/node restart)
#
# Key handling:
#   dev        OPENBAO_KEY_SHARES=1: unseal key + root token are written to
#              ${STATE_DIR}/openbao/init.json (0600, outside git).
#   test/prod  OPENBAO_PGP_KEYS=<file1,file2,...> (one public key per custodian)
#              and OPENBAO_ROOT_TOKEN_PGP_KEY=<file>: OpenBao returns every share
#              and the root token ENCRYPTED; init.json then holds ciphertext only
#              and is handed to the custodians. Unsealing prompts for decrypted
#              shares (never echoed, never written to disk).
# See docs/runbook-bootstrap.md "OpenBao key custody".
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/openbao.sh
source "${REPO_ROOT}/scripts/lib/openbao.sh"
load_env "${1:-${ENV:-}}"
mode="${2:-}"
require_cmd kubectl jq curl base64

init_file="$(openbao_init_file)"
shares="${OPENBAO_KEY_SHARES:-5}"
threshold="${OPENBAO_KEY_THRESHOLD:-3}"
replicas="$(kubectl -n "$OPENBAO_NAMESPACE" get statefulset "$OPENBAO_RELEASE" -o jsonpath='{.spec.replicas}')"

pf_pid=""
cleanup() { if [[ -n "$pf_pid" ]]; then kill "$pf_pid" 2>/dev/null || true; fi; }
trap cleanup EXIT

ca_file="${STATE_DIR}/pki/openbao-ca.crt"
kubectl -n "$OPENBAO_NAMESPACE" get secret openbao-server-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca_file"
port="${OPENBAO_LOCAL_PORT:-18200}"
host="openbao.${OPENBAO_NAMESPACE}.svc"

# api <method> <path> : JSON body on stdin (secrets never appear in argv)
api() {
  curl -fsS --noproxy '*' --cacert "$ca_file" --resolve "${host}:${port}:127.0.0.1" \
    -X "$1" -H 'Content-Type: application/json' --data-binary @- "https://${host}:${port}/v1/$2"
}
api_get() {
  curl -fsS --noproxy '*' --cacert "$ca_file" --resolve "${host}:${port}:127.0.0.1" "https://${host}:${port}/v1/$1"
}

connect() {
  # connect <pod-index> : port-forward straight to one member
  cleanup
  local pod="${OPENBAO_RELEASE}-$1"
  wait_for 300 "pod ${pod} running" \
    bash -c "[[ \"\$(kubectl -n '$OPENBAO_NAMESPACE' get pod '$pod' -o jsonpath='{.status.phase}')\" == Running ]]"
  kubectl -n "$OPENBAO_NAMESPACE" port-forward "pod/${pod}" "${port}:8200" --address 127.0.0.1 >/dev/null 2>&1 &
  pf_pid=$!
  wait_for 300 "API of ${pod}" api_get sys/seal-status
}

b64_file() { base64 -w0 < "$1"; }

do_init() {
  step "initialise OpenBao (shares=${shares}, threshold=${threshold})"
  local body
  if [[ -n "${OPENBAO_PGP_KEYS:-}" ]]; then
    [[ -n "${OPENBAO_ROOT_TOKEN_PGP_KEY:-}" ]] || die "OPENBAO_ROOT_TOKEN_PGP_KEY is required together with OPENBAO_PGP_KEYS"
    local keys='[]' f
    IFS=',' read -ra files <<<"$OPENBAO_PGP_KEYS"
    (( ${#files[@]} == shares )) || die "OPENBAO_PGP_KEYS must list exactly ${shares} public keys"
    for f in "${files[@]}"; do keys="$(jq -c --arg k "$(b64_file "$f")" '. + [$k]' <<<"$keys")"; done
    body="$(jq -n --argjson s "$shares" --argjson t "$threshold" --argjson k "$keys" \
      --arg r "$(b64_file "$OPENBAO_ROOT_TOKEN_PGP_KEY")" \
      '{secret_shares: $s, secret_threshold: $t, pgp_keys: $k, root_token_pgp_key: $r}')"
  else
    [[ "$ENV" == "dev" || "${OPENBAO_ALLOW_PLAINTEXT_KEYS:-0}" == "1" ]] \
      || die "refusing to write plaintext unseal keys for ENV=${ENV}: set OPENBAO_PGP_KEYS / OPENBAO_ROOT_TOKEN_PGP_KEY"
    body="$(jq -n --argjson s "$shares" --argjson t "$threshold" '{secret_shares: $s, secret_threshold: $t}')"
  fi
  [[ ! -e "$init_file" ]] || die "${init_file} already exists but OpenBao is not initialised; move it away first"
  api PUT sys/init <<<"$body" \
    | jq --arg env "$ENV" --arg at "$(date -u +%FT%TZ)" --argjson pgp "$([[ -n "${OPENBAO_PGP_KEYS:-}" ]] && echo true || echo false)" \
        '. + {environment: $env, initialized_at: $at, pgp_encrypted: $pgp}' \
    | write_secret_file "$init_file"
  [[ -s "$init_file" ]] || die "init returned no data"
  log "init material written to ${init_file} (mode 0600) — see the key custody procedure"
}

do_unseal() {
  # do_unseal <pod-index>
  local sealed key i=0
  sealed="$(api_get sys/seal-status | jq -r '.sealed')"
  [[ "$sealed" == "true" ]] || { log "${OPENBAO_RELEASE}-$1 already unsealed"; return 0; }
  if [[ -f "$init_file" && "$(jq -r '.pgp_encrypted' "$init_file")" != "true" ]]; then
    while [[ "$sealed" == "true" ]]; do
      key="$(jq -r --argjson i "$i" '.keys_base64[$i] // empty' "$init_file")"
      [[ -n "$key" ]] || die "not enough unseal keys in ${init_file}"
      sealed="$(jq -n --arg k "$key" '{key: $k}' | api PUT sys/unseal | jq -r '.sealed')"
      i=$((i + 1))
    done
  else
    [[ -t 0 ]] || die "${OPENBAO_RELEASE}-$1 is sealed and no plaintext keys are available: run interactively so custodians can enter their shares"
    while [[ "$sealed" == "true" ]]; do
      read -rsp "unseal key share for ${OPENBAO_RELEASE}-$1 (input hidden): " key; echo >&2
      sealed="$(jq -n --arg k "$key" '{key: $k}' | api PUT sys/unseal | jq -r '.sealed')"
    done
    unset key
  fi
  log "${OPENBAO_RELEASE}-$1 unsealed"
}

connect 0
if [[ "$(api_get sys/seal-status | jq -r '.initialized')" != "true" ]]; then
  [[ "$mode" != "--unseal" ]] || die "OpenBao is not initialised"
  do_init
fi
step "unseal ${replicas} member(s)"
do_unseal 0
for ((n = 1; n < replicas; n++)); do
  connect "$n"
  # the member joins the raft cluster via retry_join, then reports initialized
  wait_for 180 "${OPENBAO_RELEASE}-${n} to join raft" bash -c \
    "curl -fsS --noproxy '*' --cacert '$ca_file' --resolve '${host}:${port}:127.0.0.1' 'https://${host}:${port}/v1/sys/seal-status' | jq -e '.initialized == true'"
  do_unseal "$n"
done
cleanup; pf_pid=""
wait_for 180 "OpenBao pods Ready" kubectl -n "$OPENBAO_NAMESPACE" wait --for=condition=Ready pod -l "app.kubernetes.io/name=openbao,component=server" --timeout=5s
log "OpenBao is initialised, unsealed and Ready"
