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
