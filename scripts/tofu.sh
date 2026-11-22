#!/usr/bin/env bash
# The only way OpenTofu is invoked in this repository.
#
#   scripts/tofu.sh <env> <stack> <init|plan|apply|destroy|validate|output|...> [tofu args]
#
# Handles: the state backend (TOFU_BACKEND in environments/<env>/env.sh: dev =
# local file outside the checkout, test/prod = S3 outside the cluster),
# client-side state/plan encryption (TF_ENCRYPTION), common variables from
# environments/<env>/env.sh, var-files, the offline provider mirror and — for
# stacks that declare STACK_NEEDS_OPENBAO=1 in stack.env — an authenticated
# port-forward to OpenBao.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/openbao.sh
source "${REPO_ROOT}/scripts/lib/openbao.sh"

env_name="${1:?usage: tofu.sh <env> <stack> <action> [args]}"
stack="${2:?stack required}"
action="${3:?action required}"
shift 3
load_env "$env_name"
require_cmd tofu kubectl jq

stack_dir="${REPO_ROOT}/stacks/${stack}"
[[ -d "$stack_dir" && "$stack" != _* ]] || die "unknown stack: ${stack}"

STACK_NEEDS_OPENBAO=0
# shellcheck source=/dev/null
[[ -f "${stack_dir}/stack.env" ]] && source "${stack_dir}/stack.env"

# --- working dirs: keep .terraform out of the repo and separate per env --------
export TF_DATA_DIR="${STATE_DIR}/tofu/${stack}"
export TF_PLUGIN_CACHE_DIR="${BOCCOB_CACHE_DIR}/tofu-plugins"
mkdir -p "$TF_DATA_DIR" "$TF_PLUGIN_CACHE_DIR"
export TF_IN_AUTOMATION=1
export TF_INPUT=0
[[ -t 1 ]] || export TF_CLI_ARGS="-no-color"

# --- air-gap: providers from a filesystem mirror when one is present -----------
provider_mirror="${TOFU_PROVIDER_MIRROR:-${BOCCOB_CACHE_DIR}/tofu-provider-mirror}"
if [[ -d "$provider_mirror" && "${TOFU_USE_PROVIDER_MIRROR:-auto}" != "0" ]] \
   && { [[ "${TOFU_USE_PROVIDER_MIRROR:-auto}" == "1" ]] || [[ -n "$(ls -A "$provider_mirror" 2>/dev/null)" ]]; }; then
  cli_cfg="${STATE_DIR}/tofu/tofurc"
  cat > "$cli_cfg" <<CFG
provider_installation {
  filesystem_mirror {
    path = "${provider_mirror}"
  }
}
CFG
  export TF_CLI_CONFIG_FILE="$cli_cfg"
fi

# --- state encryption ----------------------------------------------------------
state_passphrase() {
  case "${STATE_ENCRYPTION:-pbkdf2}" in
    pbkdf2)
      local f="${STATE_DIR}/tofu/state-passphrase"
      [[ -f "$f" ]] || random_secret 48 | write_secret_file "$f"
      cat "$f" ;;
    pbkdf2-env)
      [[ -n "${TOFU_STATE_PASSPHRASE:-}" ]] || die "TOFU_STATE_PASSPHRASE must be set for ENV=${ENV} (state encryption passphrase from the key custody store)"
      (( ${#TOFU_STATE_PASSPHRASE} >= 32 )) || die "TOFU_STATE_PASSPHRASE must be at least 32 characters"
      printf '%s' "$TOFU_STATE_PASSPHRASE" ;;
    *) die "unsupported STATE_ENCRYPTION=${STATE_ENCRYPTION}" ;;
  esac
}
pass="$(state_passphrase)"
# STATE_READ_UNENCRYPTED=1: also READ plaintext state (e.g. `state push` of a file
# produced by `state mv` when resources move between stacks); writes still use
# aes_gcm (check afterwards: verify "tofu state is encrypted")
unencrypted="" fallback="" enforced=true
if [[ "${STATE_READ_UNENCRYPTED:-0}" == "1" ]]; then
  # only for moving state between stacks: a plaintext state from the backend would
  # be accepted unauthenticated (no AES-GCM tamper protection), so nothing else
  # may run with it
  [[ "$action" == state ]] || die "STATE_READ_UNENCRYPTED=1 is only allowed for 'state' subcommands (pull/push/mv/list), not '${action}': unset STATE_READ_UNENCRYPTED"
  warn "STATE_READ_UNENCRYPTED=1: plaintext state is accepted on READ for this command; writes stay encrypted. Unset it right after the state move."
  enforced=false   # required by OpenTofu for an unencrypted fallback; the primary method still encrypts
  unencrypted='method "unencrypted" "migrate" {}'
  fallback='  fallback {
    method = method.unencrypted.migrate
  }'
fi
TF_ENCRYPTION="$(cat <<CFG
${unencrypted}
key_provider "pbkdf2" "main" {
  passphrase = "${pass}"
}
method "aes_gcm" "main" {
  keys = key_provider.pbkdf2.main
}
state {
  method   = method.aes_gcm.main
  enforced = ${enforced}
${fallback}
}
plan {
  method   = method.aes_gcm.main
  enforced = true
}
CFG
)"
export TF_ENCRYPTION
unset pass unencrypted fallback enforced

# --- common variables ----------------------------------------------------------
export TF_VAR_environment="$ENV"
export TF_VAR_base_domain="$BASE_DOMAIN"
export TF_VAR_registry_host="$REGISTRY_HOST"
ensure_cluster_arch
export TF_VAR_cluster_arch="$CLUSTER_ARCH"
export TF_VAR_kubeconfig_path="$KUBECONFIG"
# CA of the Zot registry, for workloads that pull OCI artefacts themselves (OPA bundle)
if [[ -f "${REGISTRY_CA_FILE}" ]]; then
  TF_VAR_registry_ca_pem="$(cat "${REGISTRY_CA_FILE}")"
  export TF_VAR_registry_ca_pem
fi

# --- state backend --------------------------------------------------------------
# One state per environment and stack, never inside the cluster it manages (the
# state must survive the loss of the cluster/site). The backend type cannot come
# from a variable, so the stack's backend_override.tf (gitignored) is written for
# every run: one environment at a time per checkout.
backend_override="${stack_dir}/backend_override.tf"
case "${TOFU_BACKEND:-}" in
  local)
    umask 077
    state_dir="${STATE_DIR}/tofu/state"
    mkdir -p "$state_dir"; chmod 700 "$state_dir"
    backend_args=(-backend-config="path=${state_dir}/${stack}.tfstate") ;;
  s3)
    # off-cluster S3 target (the off-site backup target qualifies); credentials only
    # from the environment (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), never in git
    : "${TOFU_STATE_S3_ENDPOINT:?TOFU_STATE_S3_ENDPOINT (https URL of the off-cluster S3 service) is required for ENV=${ENV}}"
    : "${TOFU_STATE_S3_BUCKET:?TOFU_STATE_S3_BUCKET is required for ENV=${ENV}}"
    [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] \
      || die "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (state bucket credentials) must be exported for ENV=${ENV}"
    backend_args=(
      -backend-config="bucket=${TOFU_STATE_S3_BUCKET}"
      -backend-config="key=${TOFU_STATE_S3_PREFIX:-boccob}/${ENV}/${stack}.tfstate"
      -backend-config="region=${TOFU_STATE_S3_REGION:-us-east-1}"
      -backend-config="endpoints={s3=\"${TOFU_STATE_S3_ENDPOINT}\"}"
      -backend-config="use_path_style=true"
      -backend-config="use_lockfile=true"
      -backend-config="skip_credentials_validation=true"
      -backend-config="skip_region_validation=true"
      -backend-config="skip_requesting_account_id=true"
      -backend-config="skip_metadata_api_check=true")
    [[ -n "${TOFU_STATE_S3_CA_FILE:-}" ]] && backend_args+=(-backend-config="custom_ca_bundle=${TOFU_STATE_S3_CA_FILE}") ;;
  *) die "TOFU_BACKEND must be local or s3 (environments/${ENV}/env.sh)" ;;
esac
printf '# generated by scripts/tofu.sh (ENV=%s) - do not edit or commit\nterraform {\n  backend "%s" {}\n}\n' \
  "$ENV" "$TOFU_BACKEND" > "$backend_override"

var_files=()
for f in "${REPO_ROOT}/environments/${ENV}/common.tfvars" "${REPO_ROOT}/environments/${ENV}/${stack}.tfvars"; do
  [[ -f "$f" ]] && var_files+=("-var-file=${f}")
done

# tofu_init: -reconfigure normally; when this working directory was initialised
# with another backend type (e.g. the former kubernetes backend), the state is
# copied into the new backend first (-migrate-state; the old copy is left as is)
tofu_init() {
  local old mode=(-reconfigure)
  old="$(jq -r '.backend.type // empty' "${TF_DATA_DIR}/terraform.tfstate" 2>/dev/null || true)"
  if [[ -n "$old" && "$old" != "$TOFU_BACKEND" ]]; then
    warn "${stack}: migrating the state from backend '${old}' to '${TOFU_BACKEND}'"
    mode=(-migrate-state -force-copy)
  fi
  tofu -chdir="$stack_dir" init -input=false "${mode[@]}" "${backend_args[@]}" "$@" >/dev/null
}

if [[ "$STACK_NEEDS_OPENBAO" == "1" && "$action" != "init" && "$action" != "validate" && "$action" != "state-encrypted" ]]; then
  openbao_port_forward_start
  trap 'openbao_tofu_token_revoke; openbao_port_forward_stop' EXIT
  openbao_tofu_token
  # public certificate of the CA that signed OpenBao's listener certificate
  TF_VAR_bootstrap_ca_pem="$(cat "${STATE_DIR}/pki/openbao-ca.crt")"
  export TF_VAR_bootstrap_ca_pem
fi

case "$action" in
  init)     tofu_init "$@" ;;
  validate) tofu_init; tofu -chdir="$stack_dir" validate "$@" ;;
  plan|apply|destroy|refresh|import)
            # a saved plan carries its variables: no -var-file then
            if [[ "$action" == apply && "${1:-}" == *.tfplan ]]; then var_files=(); fi
            tofu_init; tofu -chdir="$stack_dir" "$action" -input=false "${var_files[@]}" "$@" ;;
  state-encrypted)
            # exit 0 when the STORED state is encrypted: reading it without the key must fail
            tofu_init
            if out="$(TF_ENCRYPTION='method "unencrypted" "none" {}
state {
  method   = method.unencrypted.none
  enforced = false
}' tofu -chdir="$stack_dir" state pull 2>&1)"; then
              [[ -z "$out" ]] && { echo "${stack}: no state"; exit 0; }
              echo "${stack}: state is stored WITHOUT encryption"; exit 1
            fi
            grep -q 'decryption failed' <<<"$out" || { echo "${stack}: ${out}"; exit 1; }
            echo "${stack}: encrypted" ;;
  *)        tofu_init; tofu -chdir="$stack_dir" "$action" "$@" ;;
esac
