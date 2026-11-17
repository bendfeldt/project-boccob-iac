#!/usr/bin/env bash
# Static checks: shellcheck, tofu fmt, tofu validate (no cluster needed for
# validate, backend disabled), lock file consistency.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd shellcheck tofu yq jq
rc=0

step "shellcheck"
mapfile -t files < <(find "${REPO_ROOT}/scripts" "${REPO_ROOT}/environments" "${REPO_ROOT}/stacks" -type f \( -name '*.sh' -o -name 'stack.env' \) | sort)
( cd "${REPO_ROOT}/scripts" && shellcheck -x "${files[@]}" ) || rc=1

step "python unit tests of module helper scripts (modules/*/files/test_*.py)"
for d in "${REPO_ROOT}"/modules/*/files; do
  compgen -G "${d}/test_*.py" >/dev/null || continue
  PYTHONDONTWRITEBYTECODE=1 python3 -I -m unittest discover -s "$d" -p 'test_*.py' 2>&1 | tail -1 | grep -q '^OK' \
    || { err "unit tests failed in ${d#"${REPO_ROOT}"/}"; rc=1; }
done

step "tofu fmt"
tofu fmt -check -recursive "${REPO_ROOT}" || rc=1

step "tofu validate"
export TF_PLUGIN_CACHE_DIR="${BOCCOB_CACHE_DIR}/tofu-plugins"
mkdir -p "$TF_PLUGIN_CACHE_DIR" "${BOCCOB_CACHE_DIR}/lint"
for d in "${REPO_ROOT}"/stacks/[0-9]*/; do
  stack="$(basename "$d")"
  export TF_DATA_DIR="${BOCCOB_CACHE_DIR}/lint/${stack}"
  if tofu -chdir="$d" init -backend=false -input=false >/dev/null 2>"${TF_DATA_DIR}.err" \
     && tofu -chdir="$d" validate -no-color >/dev/null 2>>"${TF_DATA_DIR}.err"; then
    log "valid: ${stack}"
  else
    err "invalid: ${stack}"; cat "${TF_DATA_DIR}.err" >&2; rc=1
  fi
done

step "lock file"
want="$(yq -c '{images: (.images | map_values({source, tag})), charts: (.charts | map_values({repo, name, version}))}' "$VERSIONS_FILE")"
have="$(yq -c '{images: (.images | map_values({source, tag})), charts: (.charts | map_values({repo, name, version}))}' "$LOCK_FILE")"
[[ "$want" == "$have" ]] || { err "versions.lock.yaml is out of date (run: make lock)"; rc=1; }
if yq -r '.images[] | .digest' "$LOCK_FILE" | grep -qv '^sha256:[0-9a-f]\{64\}$'; then err "lock file has images without digest"; rc=1; fi

[[ $rc -eq 0 ]] && log "lint OK"
exit $rc
