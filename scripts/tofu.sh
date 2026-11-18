#!/usr/bin/env bash
# The only way OpenTofu is invoked in this repository.
#
#   scripts/tofu.sh <env> <stack> <init|plan|apply|destroy|validate|output|...> [tofu args]
#
# Handles: remote state (kubernetes backend, one Secret per stack),
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
require_cmd tofu kubectl

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
export TF_VAR_kubeconfig_path="$KUBECONFIG"
# CA of the Zot registry, for workloads that pull OCI artefacts themselves (OPA bundle)
if [[ -f "${REGISTRY_CA_FILE}" ]]; then
  TF_VAR_registry_ca_pem="$(cat "${REGISTRY_CA_FILE}")"
  export TF_VAR_registry_ca_pem
fi

var_files=()
for f in "${REPO_ROOT}/environments/${ENV}/common.tfvars" "${REPO_ROOT}/environments/${ENV}/${stack}.tfvars"; do
  [[ -f "$f" ]] && var_files+=("-var-file=${f}")
done

tofu_init() {
  kubectl get namespace tofu-state >/dev/null 2>&1 || kubectl apply -f - >/dev/null <<'NS'
apiVersion: v1
kind: Namespace
metadata:
  name: tofu-state
  labels:
    app.kubernetes.io/part-of: boccob-lakehouse
    pod-security.kubernetes.io/enforce: restricted
NS
  tofu -chdir="$stack_dir" init -input=false -reconfigure \
    -backend-config="namespace=tofu-state" \
    -backend-config="secret_suffix=${stack}" \
    -backend-config="config_path=${KUBECONFIG}" \
    "$@" >/dev/null
}

if [[ "$STACK_NEEDS_OPENBAO" == "1" && "$action" != "init" && "$action" != "validate" ]]; then
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
            tofu_init; tofu -chdir="$stack_dir" "$action" -input=false "${var_files[@]}" "$@" ;;
  *)        tofu_init; tofu -chdir="$stack_dir" "$action" "$@" ;;
esac
