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

step "HA profile: RustFS PodDisruptionBudget (audit L6)"
# the module enables the chart's PDB whenever RustFS runs distributed (HA); the
# chart renders it only in distributed mode, so dev (single pod) has none
if grep -Eq 'pdb[[:space:]]*=[[:space:]]*\{[[:space:]]*create[[:space:]]*=[[:space:]]*var\.distributed' "${REPO_ROOT}/modules/rustfs/main.tf"; then
  rustfs_chart="${BOCCOB_CACHE_DIR}/charts/rustfs-$(yq -r '.charts.rustfs.version' "$VERSIONS_FILE").tgz"
  if [[ -f "$rustfs_chart" ]] && command -v helm >/dev/null; then
    if helm template lint "$rustfs_chart" -n storage --set secret.existingSecret=lint \
         --set mode.distributed.enabled=true --set mode.standalone.enabled=false \
         --set pdb.create=true --set pdb.maxUnavailable=1 2>/dev/null | grep -q '^kind: PodDisruptionBudget'; then
      log "RustFS chart renders a PodDisruptionBudget in distributed mode"
    else
      err "RustFS chart does not render a PDB in distributed mode"; rc=1
    fi
  else
    warn "RustFS chart not in ${BOCCOB_CACHE_DIR}/charts: only the module setting was checked"
  fi
else
  err "modules/rustfs: pdb.create must follow var.distributed (HA profile)"; rc=1
fi

step "lock file"
want="$(yq -c '{images: (.images | map_values({source, tag})), charts: (.charts | map_values({repo, name, version}))}' "$VERSIONS_FILE")"
have="$(yq -c '{images: (.images | map_values({source, tag})), charts: (.charts | map_values({repo, name, version}))}' "$LOCK_FILE")"
[[ "$want" == "$have" ]] || { err "versions.lock.yaml is out of date (run: make lock)"; rc=1; }
[[ "$(yq -c '.platforms' "$VERSIONS_FILE")" == "$(yq -c '.platforms' "$LOCK_FILE")" ]] \
  || { err "versions.lock.yaml platforms differ from versions.yaml (run: make lock)"; rc=1; }
# every image: a valid digest per locked platform, or the platform listed as missing
bad="$(yq -r '(.platforms | map(sub("^linux/"; ""))) as $a | .images | to_entries[]
  | .key as $k | .value as $v | $a[]
  | select(((($v.digests // {})[.] // "") | test("^sha256:[0-9a-f]{64}$")) | not)
  | select((($v.missing_platforms // []) | index(.)) == null) | "\($k)/\(.)"' "$LOCK_FILE")"
[[ -z "$bad" ]] || { err "lock file has images without a per-platform digest: ${bad//$'\n'/ }"; rc=1; }
gaps="$(yq -r '.images | to_entries[] | select(.value.missing_platforms) | "\(.key): \(.value.missing_platforms | join(","))"' "$LOCK_FILE")"
[[ -z "$gaps" ]] || warn "images without a build for some platform (docs/versions.md): ${gaps//$'\n'/; }"
bad="$(yq -r '.binaries | to_entries[] | .key as $k | .value.platforms | to_entries[]
  | select((.value.sha256 // "") | test("^[0-9a-f]{64}$") | not) | "\($k)/\(.key)"' "$LOCK_FILE")"
[[ -z "$bad" ]] || { err "lock file has binaries without sha256: ${bad//$'\n'/ }"; rc=1; }
for p in linux/amd64 linux/arm64; do
  miss="$(yq -r --arg p "$p" '.binaries | to_entries[] | select((.value.groups | index("cluster")) and (.value.platforms | has($p) or has("any") | not)) | .key' "$LOCK_FILE")"
  [[ -z "$miss" ]] || { err "cluster binaries without ${p}: ${miss//$'\n'/ }"; rc=1; }
done

[[ $rc -eq 0 ]] && log "lint OK"
exit $rc
