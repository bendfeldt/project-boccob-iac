#!/usr/bin/env bash
# dev convenience: maintain a marked block in /etc/hosts mapping the registry
# and the ingress hostnames to 127.0.0.1 (ports are published on loopback).
#   etc-hosts.sh <env> add|remove|print
#
# Linux (root): edits /etc/hosts directly.
# macOS: the scripts run as your user, so the write goes through `sudo` (asks for
# your password); it only runs when you opt in with DEV_MANAGE_ETC_HOSTS=1.
# `print` shows the block to add by hand instead.
# podman machine: the VM gets the same block (podman inside it pushes to and pulls
# from the registry name), see container_host_hosts_block in dev-up/registry-up.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
action="${2:-add}"
begin="# >>> ${CLUSTER_NAME} (managed by project-boccob-iac)"
end="# <<< ${CLUSTER_NAME}"
hosts_file="${ETC_HOSTS_FILE:-/etc/hosts}"

names="${REGISTRY_HOST%%:*}"
for h in ${DEV_INGRESS_HOSTS:-}; do names+=" ${h}.${BASE_DOMAIN}"; done
if [[ "$action" == "print" ]]; then
  printf '%s\n127.0.0.1 %s\n%s\n' "$begin" "$names" "$end"
  exit 0
fi

sudo_cmd=()
if [[ ! -w "$hosts_file" ]]; then
  if [[ "$(host_os)" == "darwin" ]] && command -v sudo >/dev/null; then
    log "updating ${hosts_file} with sudo (macOS)"
    sudo_cmd=(sudo)
  else
    die "${hosts_file} is not writable (run as root or set DEV_MANAGE_ETC_HOSTS=0)"
  fi
fi

tmp="$(mktemp)"
awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$hosts_file" > "$tmp"
if [[ "$action" == "add" ]]; then
  { echo "$begin"; echo "127.0.0.1 ${names}"; echo "$end"; } >> "$tmp"
fi
if cmp -s "$tmp" "$hosts_file"; then rm -f "$tmp"; exit 0; fi
# /etc/hosts may be a bind mount: overwrite in place instead of renaming
"${sudo_cmd[@]}" sh -c 'cat "$1" > "$2"' sh "$tmp" "$hosts_file"
rm -f "$tmp"
if [[ "$(host_os)" == "darwin" ]]; then
  # macOS caches name lookups
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
fi
