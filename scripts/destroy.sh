#!/usr/bin/env bash
# Destroy stacks in reverse order (or one stack). Requires CONFIRM=<env>.
#
#   CONFIRM=dev scripts/destroy.sh dev            all stacks, highest number first
#   CONFIRM=dev scripts/destroy.sh dev <stack>    one stack
#   CONFIRM=dev CLUSTER=1 scripts/destroy.sh dev  dev only: also remove the node and registry containers + volumes
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "${1:-${ENV:-}}"
only="${2:-${STACK:-}}"
[[ "${CONFIRM:-}" == "$ENV" ]] || die "destructive: re-run with CONFIRM=${ENV}"

if kubectl get --raw /readyz >/dev/null 2>&1; then
  stacks=()
  if [[ -n "$only" ]]; then
    stacks=("$only")
  else
    while IFS= read -r d; do stacks+=("$(basename "$d")"); done \
      < <(find "${REPO_ROOT}/stacks" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sort -r)
  fi
  for stack in "${stacks[@]}"; do
    if ! kubectl -n tofu-state get secret "tfstate-default-${stack}" >/dev/null 2>&1; then
      log "skip ${stack}: no state"; continue
    fi
    step "destroy ${stack} (${ENV})"
    "${REPO_ROOT}/scripts/tofu.sh" "$ENV" "$stack" destroy -auto-approve
  done
else
  warn "cluster not reachable: skipping tofu destroy"
fi

if [[ "${CLUSTER:-0}" == "1" ]]; then
  [[ "$CLUSTER_MODE" == "podman" ]] || die "CLUSTER=1 is only supported for podman-mode (dev) clusters"
  "${REPO_ROOT}/scripts/cluster/dev-down.sh" "$ENV" --purge
fi
