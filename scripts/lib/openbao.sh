#!/usr/bin/env bash
# OpenBao helpers: exec into the pod, port-forward for the OpenTofu provider.
# shellcheck shell=bash

OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-secrets}"
OPENBAO_RELEASE="${OPENBAO_RELEASE:-openbao}"
OPENBAO_INIT_FILE_REL="openbao/init.json"

openbao_init_file() { printf '%s/%s' "$STATE_DIR" "$OPENBAO_INIT_FILE_REL"; }

# bao_exec <pod-index> <bao args...> : runs the bao CLI inside the server pod.
# The CLI talks to the local listener; the pod's own certificate is verified
# with the mounted CA.
bao_exec() {
  local idx="$1"; shift
  kubectl -n "$OPENBAO_NAMESPACE" exec -i "${OPENBAO_RELEASE}-${idx}" -c openbao -- \
    env BAO_ADDR="https://127.0.0.1:8200" BAO_CACERT=/openbao/tls/ca.crt BAO_TLS_SERVER_NAME="openbao.${OPENBAO_NAMESPACE}.svc" "$@"
}

# openbao_status_json <pod-index> ; exit code of `bao status` is 2 when sealed, so ignore it
openbao_status_json() { bao_exec "$1" bao status -format=json 2>/dev/null || true; }

_OPENBAO_PF_PID=""
openbao_port_forward_start() {
  local port="${OPENBAO_LOCAL_PORT:-18200}" svc="svc/${OPENBAO_RELEASE}"
  # in HA only the active node accepts writes
  if kubectl -n "$OPENBAO_NAMESPACE" get svc "${OPENBAO_RELEASE}-active" >/dev/null 2>&1; then
    svc="svc/${OPENBAO_RELEASE}-active"
  fi
  kubectl -n "$OPENBAO_NAMESPACE" port-forward "$svc" "${port}:8200" --address 127.0.0.1 >/dev/null 2>&1 &
  _OPENBAO_PF_PID=$!
  kubectl -n "$OPENBAO_NAMESPACE" get secret openbao-server-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "${STATE_DIR}/pki/openbao-ca.crt"
  export VAULT_ADDR="https://127.0.0.1:${port}"
  export VAULT_CACERT="${STATE_DIR}/pki/openbao-ca.crt"
  export VAULT_TLS_SERVER_NAME="openbao.${OPENBAO_NAMESPACE}.svc"
  export BAO_ADDR="$VAULT_ADDR" BAO_CACERT="$VAULT_CACERT"
  local i
  for i in $(seq 1 30); do
    if curl -fsS --noproxy '*' --cacert "$VAULT_CACERT" --resolve "openbao.${OPENBAO_NAMESPACE}.svc:${port}:127.0.0.1" \
         "https://openbao.${OPENBAO_NAMESPACE}.svc:${port}/v1/sys/health?standbyok=true" >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "$_OPENBAO_PF_PID" 2>/dev/null || die "port-forward to OpenBao exited"
    sleep 1
  done
  die "OpenBao not reachable/unsealed through port-forward (${i}s)"
}

openbao_port_forward_stop() {
  if [[ -n "$_OPENBAO_PF_PID" ]]; then kill "$_OPENBAO_PF_PID" 2>/dev/null || true; fi
}

# Token for the OpenTofu provider: BAO_TOKEN/VAULT_TOKEN from the operator
# (prod: a short-lived admin token) or, in dev, the root token from the init file.
openbao_export_token() {
  if [[ -n "${BAO_TOKEN:-${VAULT_TOKEN:-}}" ]]; then
    export VAULT_TOKEN="${BAO_TOKEN:-$VAULT_TOKEN}"
    return 0
  fi
  local f; f="$(openbao_init_file)"
  [[ -f "$f" ]] || die "no BAO_TOKEN set and ${f} not found"
  VAULT_TOKEN="$(jq -r '.root_token // empty' "$f")"
  [[ -n "$VAULT_TOKEN" ]] || die "no usable root token in ${f} (PGP-encrypted in this environment?) — export BAO_TOKEN"
  export VAULT_TOKEN
}

# _bao_call <method> <path> [json body]: OpenBao API through the port-forward with
# VAULT_TOKEN; the token goes in through a header file, never on a command line.
_bao_call() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS --noproxy '*' --cacert "$VAULT_CACERT" -X "$method"
    --resolve "${VAULT_TLS_SERVER_NAME}:${VAULT_ADDR##*:}:127.0.0.1")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data-binary @-)
  # the process substitution must be expanded on the curl command itself
  curl "${args[@]}" -H @<(printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN") \
    "https://${VAULT_TLS_SERVER_NAME}:${VAULT_ADDR##*:}/v1/${path}" <<<"$body"
}

# Token for the OpenTofu provider, scoped by the policy tofu-deployer
# (scripts/openbao/tofu-deployer.hcl: mounts, kubernetes auth + roles, ACL
# policies, PKI, transit keys; no secret values).
#   BAO_TOKEN/VAULT_TOKEN set -> used as is (test/prod: an operator-issued
#     tofu-deployer token, see docs/compliance/runbooks/key-rotation.md)
#   dev -> the root token from the init file is used only here, to (re)write the
#     policy and mint a short-lived, non-renewable token with it; OpenTofu never
#     receives the root token. openbao_tofu_token_revoke revokes it afterwards.
_OPENBAO_TOFU_TOKEN=""
openbao_tofu_token() {
  if [[ -n "${BAO_TOKEN:-${VAULT_TOKEN:-}}" ]]; then
    openbao_export_token
    return 0
  fi
  openbao_export_token   # dev: root token from the init file
  local policy resp
  policy="$(jq -Rs '{policy: .}' "${REPO_ROOT}/scripts/openbao/tofu-deployer.hcl")"
  _bao_call PUT sys/policies/acl/tofu-deployer "$policy" >/dev/null \
    || die "cannot write OpenBao policy tofu-deployer"
  resp="$(_bao_call POST auth/token/create \
    '{"policies":["tofu-deployer"],"ttl":"1h","explicit_max_ttl":"2h","renewable":false,"display_name":"tofu-deployer","meta":{"purpose":"opentofu"}}')" \
    || die "cannot create a tofu-deployer token"
  _OPENBAO_TOFU_TOKEN="$(jq -r '.auth.client_token // empty' <<<"$resp")"
  [[ -n "$_OPENBAO_TOFU_TOKEN" ]] || die "no client_token in the token create response"
  VAULT_TOKEN="$_OPENBAO_TOFU_TOKEN"
  export VAULT_TOKEN
  log "OpenTofu uses a tofu-deployer token (1h, not renewable)"
}

openbao_tofu_token_revoke() {
  [[ -n "$_OPENBAO_TOFU_TOKEN" ]] || return 0
  VAULT_TOKEN="$_OPENBAO_TOFU_TOKEN" _bao_call POST auth/token/revoke-self >/dev/null 2>&1 || true
  _OPENBAO_TOFU_TOKEN=""
}
