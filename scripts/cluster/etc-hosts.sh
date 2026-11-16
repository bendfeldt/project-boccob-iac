#!/usr/bin/env bash
# dev convenience: maintain a marked block in /etc/hosts mapping the registry
# and the ingress hostnames to 127.0.0.1 (ports are published on loopback).
#   etc-hosts.sh <env> add|remove
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
action="${2:-add}"
begin="# >>> ${CLUSTER_NAME} (managed by project-boccob-iac)"
end="# <<< ${CLUSTER_NAME}"
hosts_file="${ETC_HOSTS_FILE:-/etc/hosts}"
[[ -w "$hosts_file" ]] || die "${hosts_file} is not writable (run as root or set DEV_MANAGE_ETC_HOSTS=0)"

tmp="$(mktemp)"
awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$hosts_file" > "$tmp"
if [[ "$action" == "add" ]]; then
  names="${REGISTRY_HOST%%:*}"
  for h in ${DEV_INGRESS_HOSTS:-}; do names+=" ${h}.${BASE_DOMAIN}"; done
  { echo "$begin"; echo "127.0.0.1 ${names}"; echo "$end"; } >> "$tmp"
fi
# /etc/hosts may be a bind mount: overwrite in place instead of renaming
cat "$tmp" > "$hosts_file"
rm -f "$tmp"
