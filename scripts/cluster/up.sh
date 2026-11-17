#!/usr/bin/env bash
# make cluster-up ENV=<env>: dispatch on CLUSTER_MODE.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
case "$CLUSTER_MODE" in
  podman) exec "${REPO_ROOT}/scripts/cluster/dev-up.sh" "$ENV" ;;
  hosts)  exec "${REPO_ROOT}/scripts/cluster/hosts-up.sh" "$ENV" ;;
  *)      die "unknown CLUSTER_MODE=${CLUSTER_MODE}" ;;
esac
