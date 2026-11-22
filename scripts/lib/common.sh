#!/usr/bin/env bash
# Shared helpers. Source from every script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck shell=bash

set -euo pipefail

# bash >= 4 (associative arrays, mapfile, ${var,,}). macOS ships bash 3.2:
# `brew install bash` and put /opt/homebrew/bin first in PATH (docs/getting-started.md).
if (( BASH_VERSINFO[0] < 4 )); then
  echo "bash ${BASH_VERSION} is too old: bash >= 4 is required (macOS: brew install bash; /opt/homebrew/bin first in PATH)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
LOCK_FILE="${LOCK_FILE:-${REPO_ROOT}/versions.lock.yaml}"
VERSIONS_FILE="${VERSIONS_FILE:-${REPO_ROOT}/versions.yaml}"
export LOCK_FILE VERSIONS_FILE

# Everything secret or machine-local lives OUTSIDE the git checkout.
BOCCOB_STATE_DIR="${BOCCOB_STATE_DIR:-${HOME}/.boccob}"
BOCCOB_CACHE_DIR="${BOCCOB_CACHE_DIR:-${HOME}/.cache/boccob}"
export BOCCOB_STATE_DIR BOCCOB_CACHE_DIR

# Pinned operator tools installed by scripts/tools-install.sh
export PATH="${BOCCOB_CACHE_DIR}/bin:${PATH}"

# --- logging -------------------------------------------------------------------
_ts() { date -u +%H:%M:%S; }
log()  { printf '%s [INFO]  %s\n' "$(_ts)" "$*" >&2; }
warn() { printf '%s [WARN]  %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s ==> %s\n' "$(_ts)" "$*" >&2; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# shellcheck source=platform.sh
source "${REPO_ROOT}/scripts/lib/platform.sh"

# --- environment ---------------------------------------------------------------
# load_env <env>: validates the name, sources environments/<env>/env.sh and
# derives the per-environment state paths.
load_env() {
  local env="${1:-${ENV:-}}"
  [[ -n "$env" ]] || die "ENV is required (dev|test|prod)"
  [[ "$env" =~ ^[a-z0-9-]+$ ]] || die "invalid ENV: $env"
  local f="${REPO_ROOT}/environments/${env}/env.sh"
  [[ -f "$f" ]] || die "unknown environment '${env}' (${f} missing)"
  ENV="$env"
  export ENV
  # decided before env.sh, which may depend on it
  CLUSTER_RUNTIME="$(cluster_runtime)"
  export CLUSTER_RUNTIME
  # shellcheck source=/dev/null
  source "$f"
  : "${CLUSTER_NAME:?env.sh must set CLUSTER_NAME}"
  : "${CLUSTER_MODE:?env.sh must set CLUSTER_MODE (podman|hosts)}"
  : "${BASE_DOMAIN:?env.sh must set BASE_DOMAIN}"
  : "${REGISTRY_HOST:?env.sh must set REGISTRY_HOST}"

  STATE_DIR="${BOCCOB_STATE_DIR}/${ENV}"
  export STATE_DIR
  mkdir -p "${STATE_DIR}"
  chmod 700 "${BOCCOB_STATE_DIR}" "${STATE_DIR}"

  KUBECONFIG="${KUBECONFIG_OVERRIDE:-${STATE_DIR}/kubeconfig}"
  export KUBECONFIG
  # the kubernetes tofu backend/provider read these
  export KUBE_CONFIG_PATH="${KUBECONFIG}"

  REGISTRY_CA_FILE="${REGISTRY_CA_FILE:-${STATE_DIR}/pki/registry-ca.crt}"
  REGISTRY_AUTH_FILE="${STATE_DIR}/registry/auth.json"
  export REGISTRY_CA_FILE REGISTRY_AUTH_FILE
  export HELM_REGISTRY_CONFIG="${REGISTRY_AUTH_FILE}"

  # Internal names must never go through an outbound proxy.
  local np=".${BASE_DOMAIN#*.},${REGISTRY_HOST%%:*},localhost,127.0.0.1"
  export NO_PROXY="${NO_PROXY:+${NO_PROXY},}${np}"
  export no_proxy="${NO_PROXY}"

  setup_trust_bundle
  # architecture of the cluster nodes: selects the per-arch image digests and
  # binaries of versions.lock.yaml. Best effort here (a stopped podman machine
  # must not break e.g. `make doctor`); image_digest fails clearly later.
  ensure_cluster_arch soft
}

# ensure_cluster_arch [soft]: sets and exports CLUSTER_ARCH (amd64|arm64)
#   CLUSTER_ARCH set     -> validated (test/prod: environments/<env>/env.sh)
#   podman, native       -> this machine's architecture
#   podman-machine       -> the VM's architecture (podman info), not the Mac's
ensure_cluster_arch() {
  local soft="${1:-}" raw=""
  if [[ -n "${CLUSTER_ARCH:-}" ]]; then
    CLUSTER_ARCH="$(arch_or_die "$CLUSTER_ARCH" "CLUSTER_ARCH")"
  elif [[ "${CLUSTER_MODE:-}" == "podman" && "$(cluster_runtime)" == "podman-machine" ]]; then
    if ! raw="$(podman info --format '{{.Host.Arch}}' 2>/dev/null)" || [[ -z "$raw" ]]; then
      [[ "$soft" == "soft" ]] && return 0
      die "cannot reach the podman machine to read its architecture (podman machine start; or set CLUSTER_ARCH)"
    fi
    CLUSTER_ARCH="$(arch_or_die "$raw" "podman machine")"
  elif [[ "${CLUSTER_MODE:-}" == "podman" ]]; then
    CLUSTER_ARCH="$(host_arch)"
  else
    [[ "$soft" == "soft" ]] && return 0
    die "CLUSTER_ARCH is not set for ENV=${ENV:-?} (environments/<env>/env.sh: amd64 or arm64)"
  fi
  export CLUSTER_ARCH
}
# Go tools (helm, tofu, skopeo, cosign, trivy) honour SSL_CERT_FILE on Linux. Build one
# bundle = system/proxy CAs + bootstrap registry CA (+ platform CA once it exists).
# macOS: Go programs verify against the macOS keychain and ignore SSL_CERT_FILE, so
# the CAs must be trusted in the System keychain (scripts/cluster/macos-trust.sh);
# curl and python still use this bundle.
setup_trust_bundle() {
  local base="${BOCCOB_BASE_CA_BUNDLE:-${SSL_CERT_FILE:-}}" f
  if [[ -z "$base" ]]; then
    # Debian/Ubuntu, Fedora/RHEL, macOS (LibreSSL bundle of the system roots)
    for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
      [[ -f "$f" ]] && { base="$f"; break; }
    done
  fi
  local out="${STATE_DIR}/pki/trust-bundle.crt"
  # do not stack our own bundle onto itself
  [[ "$base" == "$out" ]] && base="/etc/ssl/certs/ca-certificates.crt"
  export BOCCOB_BASE_CA_BUNDLE="$base"
  mkdir -p "${STATE_DIR}/pki"
  {
    [[ -f "$base" ]] && cat "$base"
    [[ -f "${REGISTRY_CA_FILE}" ]] && cat "${REGISTRY_CA_FILE}"
    [[ -f "${STATE_DIR}/pki/platform-ca.crt" ]] && cat "${STATE_DIR}/pki/platform-ca.crt"
    true
  } > "${out}.tmp"
  mv "${out}.tmp" "$out"
  export SSL_CERT_FILE="$out"
  export CURL_CA_BUNDLE="$out"
}

# --- lock file -----------------------------------------------------------------
_LOCK_JSON=""
lock_json() {
  if [[ -z "$_LOCK_JSON" ]]; then
    [[ -f "$LOCK_FILE" ]] || die "lock file missing: ${LOCK_FILE} (run: make lock)"
    _LOCK_JSON="$(yq -c . "$LOCK_FILE")"
  fi
  printf '%s' "$_LOCK_JSON"
}
# lock_q <jq filter> [jq args...]
lock_q() {
  local filter="$1"; shift
  lock_json | jq -r "$@" "$filter"
}
# lock_keys <images|charts|binaries> [groups-csv]  -> keys, optionally filtered by group
# MIRROR_EXCLUDE_GROUPS=a,b drops entries whose groups are ALL excluded (optional
# components an environment does not deploy, e.g. observability-ui on dev).
lock_keys() {
  local kind="$1" groups="${2:-}"
  lock_json | jq -r --arg kind "$kind" --arg groups "$groups" --arg ex "${MIRROR_EXCLUDE_GROUPS:-}" '
    ($groups | split(",") | map(select(length > 0))) as $g
    | ($ex | split(",") | map(select(length > 0))) as $x
    | .[$kind] | to_entries[]
    | select(($g | length) == 0 or ((.value.groups // []) | any(. as $y | $g | index($y))))
    | select(($x | length) == 0 or ((.value.groups // []) | length == 0) or (((.value.groups // []) | all(. as $y | $x | index($y))) | not))
    | .key'
}
# image_digest <key> [arch] -> manifest digest of the linux/<arch> image (default: CLUSTER_ARCH)
image_digest() {
  local key="$1" arch="${2:-}" d
  if [[ -z "$arch" ]]; then ensure_cluster_arch; arch="$CLUSTER_ARCH"; fi
  d="$(lock_q '.images[$k].digests[$a] // ""' --arg k "$key" --arg a "$arch")"
  [[ "$d" == sha256:* ]] || die "image ${key}: no linux/${arch} digest in ${LOCK_FILE} (run make lock; docs/versions.md lists images without that platform)"
  printf '%s' "$d"
}
# image_zot_repo <key>      -> <registry>/<source>
image_zot_repo() { printf '%s/%s' "${REGISTRY_HOST}" "$(lock_q '.images[$k].source' --arg k "$1")"; }
# image_zot_ref <key> [arch]       -> <registry>/<source>:<tag>@<digest>
image_zot_ref() {
  printf '%s:%s@%s' "$(image_zot_repo "$1")" "$(lock_q '.images[$k].tag' --arg k "$1")" "$(image_digest "$1" "${2:-}")"
}
# image_zot_digest_ref <key> [arch] -> <registry>/<source>@<digest>  (for tools that reject tag+digest)
image_zot_digest_ref() { printf '%s@%s' "$(image_zot_repo "$1")" "$(image_digest "$1" "${2:-}")"; }
# image_upstream_ref <key> [arch]  -> <source>@<digest>
image_upstream_ref() { printf '%s@%s' "$(lock_q '.images[$k].source' --arg k "$1")" "$(image_digest "$1" "${2:-}")"; }

# --- binaries (per platform) ----------------------------------------------------
# binary_platform <key> [platform] -> the platform entry to use for a binary:
#   [platform] or, by group: "cluster" binaries -> linux/<CLUSTER_ARCH>,
#   tools -> this machine (<os>/<arch>); "any" for platform-independent files
binary_platform() {
  local key="$1" want="${2:-}" have
  have="$(lock_q '.binaries[$k].platforms | keys | join(" ")' --arg k "$key")"
  if [[ " $have " == *" any "* ]]; then printf 'any'; return 0; fi
  if [[ -z "$want" ]]; then
    if lock_q '(.binaries[$k].groups // []) | index("cluster") != null' --arg k "$key" | grep -q true; then
      ensure_cluster_arch; want="linux/${CLUSTER_ARCH}"
    else
      want="$(host_platform)"
    fi
  fi
  [[ " $have " == *" ${want} "* ]] || die "binary ${key}: no ${want} build in ${LOCK_FILE} (available: ${have})"
  printf '%s' "$want"
}
# binary_field <key> <platform> <url|file|sha256>
binary_field() { lock_q '.binaries[$k].platforms[$p][$f]' --arg k "$1" --arg p "$2" --arg f "$3"; }

# fetch_verified <url> <dest> <sha256|""> : cached download with checksum check
fetch_verified() {
  local url="$1" dest="$2" sum="${3:-}"
  if [[ -f "$dest" && -n "$sum" && "$(sha256_of "$dest")" == "$sum" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "download ${url}"
  curl -fsSL --retry 3 -o "${dest}.part" "$url"
  if [[ -n "$sum" ]]; then
    local got; got="$(sha256_of "${dest}.part")"
    [[ "$got" == "$sum" ]] || { rm -f "${dest}.part"; die "checksum mismatch for ${url}: got ${got}, want ${sum}"; }
  fi
  mv "${dest}.part" "$dest"
}

# random_secret <bytes> : url-safe random string, never echoed to logs by callers
random_secret() { openssl rand -base64 "${1:-32}" | tr -d '\n=' | tr '+/' '-_'; }

# write_secret_file <path> : reads stdin, writes 0600 atomically
write_secret_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  chmod 700 "$(dirname "$path")"
  ( umask 077; cat > "${path}.tmp" )
  mv "${path}.tmp" "$path"
  chmod 600 "$path"
}

# podman_container_alive <name>: true only when the container really runs.
# After a host crash/reboot podman can still report "running" for a container
# whose process is gone; such a stale container is removed (volumes are kept)
# so the caller recreates it.
podman_container_alive() {
  local name="$1" pid
  podman container exists "$name" || return 1
  if [[ "$(podman inspect -f '{{.State.Running}}' "$name")" == "true" ]]; then
    pid="$(podman inspect -f '{{.State.Pid}}' "$name")"
    container_host_exec "test -d /proc/${pid}" && return 0
    warn "container ${name} is stale (host restarted?); removing it, data volumes are kept"
    podman rm -f "$name" >/dev/null 2>&1 || true
    return 1
  fi
  return 1
}

wait_for() {
  # wait_for <timeout-seconds> <description> <command...>
  local timeout="$1" desc="$2"; shift 2
  local start; start="$(date +%s)"
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > timeout )); then
      die "timeout (${timeout}s) waiting for ${desc}"
    fi
    sleep 3
  done
}
