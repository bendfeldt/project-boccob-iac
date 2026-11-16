#!/usr/bin/env bash
# Deploy stacks in order with OpenTofu.
#
#   scripts/deploy.sh <env>            all stacks (stacks/NN-*), lowest number first
#   scripts/deploy.sh <env> <stack>    one stack
#   PLAN_ONLY=1 scripts/deploy.sh ...  plan instead of apply
#
# Per-stack settings live in stacks/<stack>/stack.env:
#   STACK_NEEDS_OPENBAO=1      tofu needs an authenticated OpenBao connection
#   STACK_POST_APPLY=<script>  run "<script> <env>" after a successful apply
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "${1:-${ENV:-}}"
only="${2:-${STACK:-}}"
require_cmd tofu kubectl

kubectl get --raw /readyz >/dev/null 2>&1 || die "cluster not reachable with ${KUBECONFIG} (make cluster-up ENV=${ENV})"

stacks=()
if [[ -n "$only" ]]; then
  [[ -d "${REPO_ROOT}/stacks/${only}" ]] || die "unknown stack: ${only}"
  stacks=("$only")
else
  while IFS= read -r d; do stacks+=("$(basename "$d")"); done \
    < <(find "${REPO_ROOT}/stacks" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sort)
fi

for stack in "${stacks[@]}"; do
  # shellcheck disable=SC2034  # consumed by scripts/tofu.sh, reset here for clarity
  STACK_NEEDS_OPENBAO=0
  STACK_POST_APPLY=""
  # shellcheck source=/dev/null
  [[ -f "${REPO_ROOT}/stacks/${stack}/stack.env" ]] && source "${REPO_ROOT}/stacks/${stack}/stack.env"

  if [[ "${PLAN_ONLY:-0}" == "1" ]]; then
    step "plan ${stack} (${ENV})"
    "${REPO_ROOT}/scripts/tofu.sh" "$ENV" "$stack" plan
    continue
  fi

  step "apply ${stack} (${ENV})"
  "${REPO_ROOT}/scripts/tofu.sh" "$ENV" "$stack" apply -auto-approve

  if [[ -n "$STACK_POST_APPLY" ]]; then
    step "post-apply ${stack}: ${STACK_POST_APPLY}"
    "${REPO_ROOT}/${STACK_POST_APPLY}" "$ENV"
  fi
done
log "deploy finished: ${stacks[*]}"
