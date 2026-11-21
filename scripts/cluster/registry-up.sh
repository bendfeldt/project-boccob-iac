#!/usr/bin/env bash
# dev: run the Zot OCI registry as a Podman container on the cluster's podman
# network. It is the bootstrap registry: the k3s node can only pull from it.
#   - TLS with a bootstrap CA generated into ${STATE_DIR}/pki (never in git)
#   - anonymous read, authenticated push (htpasswd, bcrypt)
# test/prod run Zot the same way on a registry host (see docs/runbook-bootstrap.md).
# CLUSTER_RUNTIME=podman-machine (macOS): the container runs in the rootful VM; its
# configuration is copied into the VM (DEV_MACHINE_DIR) because bind mounts are
# resolved there, the VM gets an /etc/hosts entry and certs.d trust for the
# registry, and the Mac needs the registry name (/etc/hosts) and the CA in the
# System keychain (scripts/cluster/macos-trust.sh).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
load_env "${1:-${ENV:-}}"
require_cmd podman openssl helm jq curl
require_rootful_podman
runtime="$(cluster_runtime)"

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
zot_image="$zot_upstream"
if ! podman image exists "$zot_upstream"; then
  bundle_img="${BUNDLE_DIR:-}/images/${CLUSTER_ARCH}/zot.tar"
  if [[ -n "${BUNDLE_DIR:-}" && -f "$bundle_img" ]]; then
    log "loading zot image from bundle"
    if [[ "$runtime" == "podman-machine" ]]; then
      # containers-storage of the VM is not reachable for skopeo on the Mac: stream it
      zot_image="$(podman load -q -i "$bundle_img" | awk '/Loaded image/ {print $NF; exit}')"
      [[ -n "$zot_image" ]] || die "podman load of ${bundle_img} failed"
    else
      skopeo copy --quiet --preserve-digests "oci-archive:${bundle_img}" "containers-storage:${zot_upstream}"
    fi
  else
    log "pulling ${zot_upstream}"
    podman pull -q "$zot_upstream" >/dev/null
  fi
fi

# bind mounts are resolved on the container host (the VM in podman-machine mode)
zot_etc="$(container_host_sync_dir "${CFG}/etc" "${DEV_MACHINE_DIR:-/var/lib/boccob/${ENV}}/registry-etc")"
mount_opts="ro"
# Fedora CoreOS (podman machine) enforces SELinux: relabel the copied files
[[ "$runtime" == "podman-machine" ]] && mount_opts="ro,z"

if podman_container_alive "$ZOT_NAME"; then
  # pick up config/cert changes
  if [[ "${CFG}/etc/config.json" -nt "${CFG}/.started" || "${CFG}/etc/tls.crt" -nt "${CFG}/.started" ]]; then
    podman restart "$ZOT_NAME" >/dev/null
  fi
else
  podman rm -f "$ZOT_NAME" >/dev/null 2>&1 || true
  podman volume exists "${ZOT_NAME}-data" || podman volume create "${ZOT_NAME}-data" >/dev/null
  podman volume exists "${ZOT_NAME}-log" || podman volume create "${ZOT_NAME}-log" >/dev/null
  podman run -d --name "$ZOT_NAME" \
    --network "${CLUSTER_NAME}" --network-alias "$REG_NAME" \
    -p "${DEV_PUBLISH_ADDR:-127.0.0.1}:${DEV_REGISTRY_PORT:-$REG_PORT}:${REG_PORT}" \
    --restart always \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp \
    -v "${ZOT_NAME}-data:/var/lib/registry" \
    -v "${ZOT_NAME}-log:/var/log/zot" \
    -v "${zot_etc}:/etc/zot:${mount_opts}" \
    "$zot_image" serve /etc/zot/config.json >/dev/null
fi
touch "${CFG}/.started"

if [[ "$runtime" == "podman-machine" ]]; then
  step "podman machine: registry name and trust inside the VM"
  # podman in the VM pulls the node image and pushes solution releases by name
  container_host_hosts_block "$CLUSTER_NAME" "127.0.0.1 ${REG_NAME}"
  container_host_write_file "/etc/containers/certs.d/${REGISTRY_HOST}/ca.crt" 0644 < "${REGISTRY_CA_FILE}"
fi

if [[ "${DEV_MANAGE_ETC_HOSTS:-0}" == "1" ]]; then
  "${REPO_ROOT}/scripts/cluster/etc-hosts.sh" "$ENV" add
fi
if ! name_resolves "$REG_NAME"; then
  err "${REG_NAME} does not resolve on this machine. Either let the scripts manage /etc/hosts"
  err "(macOS asks for your sudo password):  DEV_MANAGE_ETC_HOSTS=1 make cluster-up ENV=${ENV}"
  err "or add this block to /etc/hosts yourself:"
  "${REPO_ROOT}/scripts/cluster/etc-hosts.sh" "$ENV" print >&2
  exit 1
fi
if [[ "$(host_os)" == "darwin" ]]; then
  # Go programs on macOS (skopeo, helm, tofu, cosign, oras) only trust the keychain
  # DEV_TRUST_CA=1: add it now (sudo); otherwise stop with the instruction
  if ! "${REPO_ROOT}/scripts/cluster/macos-trust.sh" "$ENV" check; then
    if [[ "${DEV_TRUST_CA:-0}" == "1" ]]; then
      "${REPO_ROOT}/scripts/cluster/macos-trust.sh" "$ENV" add || die "could not add the registry CA to the System keychain"
    else
      die "the registry CA is not trusted by macOS yet: make macos-trust ENV=${ENV} (asks for sudo), or DEV_TRUST_CA=1 make cluster-up ENV=${ENV}"
    fi
  fi
fi
setup_trust_bundle
wait_for 60 "zot at https://${REGISTRY_HOST}" registry_ready
log "registry ready: https://${REGISTRY_HOST} (CA: ${REGISTRY_CA_FILE})"
