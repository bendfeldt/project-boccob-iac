#!/usr/bin/env bash
# Stop the dev cluster.   dev-down.sh <env> [--purge]
#   default  stop + remove the node and registry containers, KEEP volumes and
#            local state (make cluster-up brings everything back)
#   --purge  also delete the volumes, the podman network and ${STATE_DIR}
#            (unseal keys, CA, state passphrase: the environment is gone for good)
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
[[ "$CLUSTER_MODE" == "podman" ]] || die "dev-down.sh only handles CLUSTER_MODE=podman"
NODE="${CLUSTER_NAME}-server-0"; ZOT="${CLUSTER_NAME}-zot"
podman rm -f "$NODE" "$ZOT" >/dev/null 2>&1 || true
if [[ "${2:-}" == "--purge" ]]; then
  for v in "${NODE}-data" "${NODE}-kubelet" "${NODE}-log" "${ZOT}-data" "${ZOT}-log"; do
    podman volume rm -f "$v" >/dev/null 2>&1 || true
  done
  podman network rm "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  if [[ "${DEV_MANAGE_ETC_HOSTS:-0}" == "1" ]]; then "${REPO_ROOT}/scripts/cluster/etc-hosts.sh" "$ENV" remove; fi
  if [[ "$CLUSTER_RUNTIME" == "podman-machine" ]]; then
    container_host_hosts_block "$CLUSTER_NAME" ""
    container_host_exec "rm -rf '${DEV_MACHINE_DIR:-/var/lib/boccob/${ENV}}' '/etc/containers/certs.d/${REGISTRY_HOST}'" || true
  fi
  rm -rf "${STATE_DIR}"
  log "purged ${CLUSTER_NAME} including ${STATE_DIR}"
else
  log "stopped ${CLUSTER_NAME} (volumes and ${STATE_DIR} kept)"
fi
