#!/usr/bin/env bash
# dev: run the Zot OCI registry as a Podman container on the cluster's podman
# network. It is the bootstrap registry: the k3s node can only pull from it.
#   - TLS with a bootstrap CA generated into ${STATE_DIR}/pki (never in git)
#   - anonymous read, authenticated push (htpasswd, bcrypt)
# test/prod run Zot the same way on a registry host (see docs/runbook-bootstrap.md).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
load_env "${1:-${ENV:-}}"
require_cmd podman openssl helm jq curl

ZOT_NAME="${CLUSTER_NAME}-zot"
REG_NAME="${REGISTRY_HOST%%:*}"
REG_PORT="${REGISTRY_HOST##*:}"
PKI="${STATE_DIR}/pki"
CFG="${STATE_DIR}/registry"
mkdir -p "$PKI" "$CFG/etc"
chmod 700 "$PKI" "$CFG"

step "podman network ${CLUSTER_NAME}"
podman network exists "${CLUSTER_NAME}" || podman network create "${CLUSTER_NAME}" >/dev/null

step "bootstrap registry CA + server certificate"
if [[ ! -f "${PKI}/registry-ca.crt" ]]; then
  ( umask 077
    openssl ecparam -name prime256v1 -genkey -noout -out "${PKI}/registry-ca.key"
    openssl req -x509 -new -key "${PKI}/registry-ca.key" -sha256 -days 3650 \
      -subj "/O=Boccob Lakehouse/OU=${ENV}/CN=${CLUSTER_NAME} bootstrap registry CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -out "${PKI}/registry-ca.crt" )
  log "created ${PKI}/registry-ca.crt"
fi
if [[ ! -f "${CFG}/etc/tls.crt" ]] || ! openssl x509 -checkend 2592000 -noout -in "${CFG}/etc/tls.crt" >/dev/null; then
  ( umask 077
    openssl ecparam -name prime256v1 -genkey -noout -out "${CFG}/etc/tls.key"
    openssl req -new -key "${CFG}/etc/tls.key" -subj "/O=Boccob Lakehouse/CN=${REG_NAME}" -out "${CFG}/tls.csr"
    printf 'subjectAltName=DNS:%s,DNS:%s,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\nbasicConstraints=critical,CA:FALSE\n' \
      "$REG_NAME" "$ZOT_NAME" > "${CFG}/tls.ext"
    openssl x509 -req -in "${CFG}/tls.csr" -CA "${PKI}/registry-ca.crt" -CAkey "${PKI}/registry-ca.key" \
      -CAcreateserial -days 825 -sha256 -extfile "${CFG}/tls.ext" -out "${CFG}/etc/tls.crt" 2>/dev/null )
  log "issued registry certificate for ${REG_NAME}"
fi

step "registry push credentials"
pwfile="$(registry_push_password_file)"
if [[ ! -f "$pwfile" ]]; then
  random_secret 32 | write_secret_file "$pwfile"
fi
if [[ ! -f "${CFG}/etc/htpasswd" || "$pwfile" -nt "${CFG}/etc/htpasswd" ]]; then
  # bcrypt without extra tooling: helm's sprig `htpasswd` function, values via stdin
  hc="$(mktemp -d)"
  mkdir -p "${hc}/templates"
  printf 'apiVersion: v2\nname: htpasswd\nversion: 0.0.1\n' > "${hc}/Chart.yaml"
  printf 'line: {{ htpasswd .Values.u .Values.p | quote }}\n' > "${hc}/templates/h.yaml"
  jq -n --arg u "$REGISTRY_PUSH_USER" --arg p "$(cat "$pwfile")" '{u: $u, p: $p}' \
    | helm template h "$hc" -f - | sed -n 's/^line: "\(.*\)"$/\1/p' | write_secret_file "${CFG}/etc/htpasswd"
  rm -rf "$hc"
  [[ -s "${CFG}/etc/htpasswd" ]] || die "failed to render htpasswd"
fi
registry_login

cat > "${CFG}/config.json.new" <<JSON
{
  "distSpecVersion": "1.1.1",
  "storage": {
    "rootDirectory": "/var/lib/registry",
    "gc": true,
    "dedupe": true
  },
  "http": {
    "address": "0.0.0.0",
    "port": "${REG_PORT}",
    "compat": ["docker2s2"],
    "tls": { "cert": "/etc/zot/tls.crt", "key": "/etc/zot/tls.key" },
    "auth": { "htpasswd": { "path": "/etc/zot/htpasswd" } },
    "accessControl": {
      "repositories": {
        "**": {
          "anonymousPolicy": ["read"],
          "defaultPolicy": ["read"],
          "policies": [
            { "users": ["${REGISTRY_PUSH_USER}"], "actions": ["read", "create", "update", "delete"] }
          ]
        }
      }
    }
  },
  "log": { "level": "info", "audit": "/var/log/zot/audit.log" }
}
JSON
if ! cmp -s "${CFG}/config.json.new" "${CFG}/etc/config.json"; then
  mv "${CFG}/config.json.new" "${CFG}/etc/config.json"
else
  rm -f "${CFG}/config.json.new"
fi

step "zot container ${ZOT_NAME}"
zot_upstream="$(image_upstream_ref zot)"
if ! podman image exists "$zot_upstream"; then
  bundle_img="${BUNDLE_DIR:-}/images/zot.tar"
  if [[ -n "${BUNDLE_DIR:-}" && -f "$bundle_img" ]]; then
    log "loading zot image from bundle"
    skopeo copy --quiet --preserve-digests "oci-archive:${bundle_img}" "containers-storage:${zot_upstream}"
  else
    log "pulling ${zot_upstream}"
    podman pull -q "$zot_upstream" >/dev/null
  fi
fi

if podman container exists "$ZOT_NAME"; then
  if [[ "$(podman inspect -f '{{.State.Running}}' "$ZOT_NAME")" != "true" ]]; then podman start "$ZOT_NAME" >/dev/null; fi
  # pick up config/cert changes
  if [[ "${CFG}/etc/config.json" -nt "${CFG}/.started" || "${CFG}/etc/tls.crt" -nt "${CFG}/.started" ]]; then
    podman restart "$ZOT_NAME" >/dev/null
  fi
else
  podman volume exists "${ZOT_NAME}-data" || podman volume create "${ZOT_NAME}-data" >/dev/null
  podman volume exists "${ZOT_NAME}-log" || podman volume create "${ZOT_NAME}-log" >/dev/null
  podman run -d --name "$ZOT_NAME" \
    --network "${CLUSTER_NAME}" --network-alias "$REG_NAME" \
    -p "127.0.0.1:${DEV_REGISTRY_PORT:-$REG_PORT}:${REG_PORT}" \
    --restart always \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp \
    -v "${ZOT_NAME}-data:/var/lib/registry" \
    -v "${ZOT_NAME}-log:/var/log/zot" \
    -v "${CFG}/etc:/etc/zot:ro" \
    "$zot_upstream" serve /etc/zot/config.json >/dev/null
fi
touch "${CFG}/.started"

if [[ "${DEV_MANAGE_ETC_HOSTS:-0}" == "1" ]]; then
  "${REPO_ROOT}/scripts/cluster/etc-hosts.sh" "$ENV" add
fi
setup_trust_bundle
wait_for 60 "zot at https://${REGISTRY_HOST}" registry_ready
log "registry ready: https://${REGISTRY_HOST} (CA: ${REGISTRY_CA_FILE})"
