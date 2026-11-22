#!/usr/bin/env bash
# Deploy stacks in order with OpenTofu.
#
#   scripts/deploy.sh <env>            all stacks (stacks/NN-*), lowest number first
#   scripts/deploy.sh <env> <stack>    one stack
#   PLAN_ONLY=1 scripts/deploy.sh ...  plan instead of apply
#   ALLOW_DESTROY=<env>                 accept a plan that deletes/replaces OpenBao
#                                       (vault_*), namespaces, CNPG clusters, RustFS, PVCs
#
# Per-stack settings live in stacks/<stack>/stack.env:
#   STACK_NEEDS_OPENBAO=1      tofu needs an authenticated OpenBao connection
#   STACK_POST_APPLY=<script>  run "<script> <env>" after a successful apply
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "${1:-${ENV:-}}"
only="${2:-${STACK:-}}"
require_brew_prereqs
require_cmd tofu kubectl jq

kubectl get --raw /readyz >/dev/null 2>&1 || die "cluster not reachable with ${KUBECONFIG} (make cluster-up ENV=${ENV})"

# Admission policies must enforce in prod (and wherever REQUIRE_POLICY_ENFORCE=1
# in env.sh): refuse to deploy while 31-policy would run in Audit mode.
# A staged roll-out can acknowledge it explicitly: POLICY_AUDIT_ACK=<env>.
policy_enforced() {
  local f="${REPO_ROOT}/environments/${ENV}/31-policy.tfvars"
  [[ -f "$f" ]] \
    && grep -Eq '^[[:space:]]*policy_mode[[:space:]]*=[[:space:]]*"Enforce"' "$f" \
    && grep -Eq '^[[:space:]]*signature_mode[[:space:]]*=[[:space:]]*"Enforce"' "$f"
}
if [[ "$ENV" == "prod" || "${REQUIRE_POLICY_ENFORCE:-0}" == "1" ]] && ! policy_enforced; then
  if [[ "${POLICY_AUDIT_ACK:-}" == "$ENV" ]]; then
    warn "admission policies are NOT enforced in ${ENV} (acknowledged with POLICY_AUDIT_ACK)"
  else
    die "environments/${ENV}/31-policy.tfvars must set policy_mode and signature_mode to \"Enforce\" (or POLICY_AUDIT_ACK=${ENV} for a documented, temporary exception)"
  fi
fi

# destroy_guard <stack> <plan file>: a saved plan that deletes or replaces an
# irreplaceable resource (scripts/lib/destroy-guard.jq) is refused unless ALLOW_DESTROY=<env>.
# (Buckets are never deleted by OpenTofu: the RustFS provisioning Job only creates.)
destroy_guard() {
  local stack="$1" plan="$2" hits
  hits="$("${REPO_ROOT}/scripts/tofu.sh" "$ENV" "$stack" show -json "$plan" | jq -r -f "${REPO_ROOT}/scripts/lib/destroy-guard.jq")" \
    || die "cannot read plan ${plan}"
  [[ -z "$hits" ]] && return 0
  if [[ "${ALLOW_DESTROY:-}" == "$ENV" ]]; then
    warn "plan of ${stack} deletes/replaces irreplaceable resources (ALLOW_DESTROY=${ENV}):"$'\n'"${hits}"
  else
    die "plan of ${stack} would delete or replace irreplaceable resources:"$'\n'"${hits}"$'\n'"review it (make plan ENV=${ENV} STACK=${stack}); set ALLOW_DESTROY=${ENV} only after a backup and four-eyes review"
  fi
}

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
  # plan to a file, refuse destructive changes of irreplaceable resources, then
  # apply exactly that plan
  plan_file="${STATE_DIR}/tofu/${stack}.tfplan"
  mkdir -p "$(dirname "$plan_file")"; rm -f "$plan_file"
  "${REPO_ROOT}/scripts/tofu.sh" "$ENV" "$stack" plan -out="$plan_file"
  destroy_guard "$stack" "$plan_file"
  "${REPO_ROOT}/scripts/tofu.sh" "$ENV" "$stack" apply "$plan_file"
  rm -f "$plan_file"

  if [[ -n "$STACK_POST_APPLY" ]]; then
    step "post-apply ${stack}: ${STACK_POST_APPLY}"
    "${REPO_ROOT}/${STACK_POST_APPLY}" "$ENV"
  fi
done
log "deploy finished: ${stacks[*]}"
