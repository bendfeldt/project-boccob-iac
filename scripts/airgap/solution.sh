#!/usr/bin/env bash
# Air-gap path for the solution artefacts (audit R3-2): the code location image
# and the OPA bundle, by digest, together with their referrers (the cosign
# signature bundles, attestations).
#
#   solution.sh bundle <env> <dir> <ref@sha256:..>...  connected side: Zot of <env> -> dir
#   solution.sh load   <env> <dir>                     air-gapped side: dir -> Zot of <env>
#
#   make solution-bundle ENV=dev BUNDLE=<dir> REFS="<image ref> <bundle ref>"
#   make solution-load   ENV=prod BUNDLE=<dir>
#
# Each artefact becomes an OCI image layout below <dir>/oci/<n>, listed with its
# repository path, tag and digest in <dir>/artefacts.json; SHA256SUMS covers the
# directory. `load` verifies the checksums, copies every artefact (oras copy -r,
# digests unchanged) into the target Zot under the same repository path, checks
# the digest and verifies the cosign signature with the target's platform key
# (scripts/supply-chain/sign.sh verify). Signing key: test/prod sign with their
# own OpenBao transit key; artefacts signed by another environment's key fail
# the check there - re-sign with `make sign ENV=<target>` after review.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"

cmd="${1:-}"; shift || true
load_env "${1:-${ENV:-}}"; shift || true
require_cmd oras jq
dir="${1:?usage: solution.sh bundle|load <env> <dir> [refs...]}"; shift || true

case "$cmd" in
  bundle)
    [[ $# -gt 0 ]] || die "no artefact references given (REFS=\"<image@sha256:..> <bundle@sha256:..>\")"
    registry_login
    mkdir -p "${dir}/oci"
    entries='[]'; n=0
    for ref in "$@"; do
      [[ "$ref" == "${REGISTRY_HOST}/"*@sha256:* ]] || die "not a digest reference in ${REGISTRY_HOST}: ${ref}"
      repo="${ref#"${REGISTRY_HOST}/"}"; repo="${repo%@*}"; digest="${ref##*@}"
      tag="$(oras repo tags --ca-file "$REGISTRY_CA_FILE" --registry-config "$REGISTRY_AUTH_FILE" "${REGISTRY_HOST}/${repo}" 2>/dev/null \
        | while read -r t; do
            [[ "$(oras resolve --ca-file "$REGISTRY_CA_FILE" --registry-config "$REGISTRY_AUTH_FILE" "${REGISTRY_HOST}/${repo}:${t}" 2>/dev/null)" == "$digest" ]] && { echo "$t"; break; }
          done)"
      n=$((n + 1))
      log "save ${repo}@${digest} (tag ${tag:-none}) with referrers"
      oras copy -r --from-ca-file "$REGISTRY_CA_FILE" --from-registry-config "$REGISTRY_AUTH_FILE" \
        "$ref" --to-oci-layout "${dir}/oci/${n}@${digest}" >/dev/null
      entries="$(jq -c --arg r "$repo" --arg d "$digest" --arg t "$tag" --arg p "oci/${n}" '. + [{repository: $r, digest: $d, tag: $t, layout: $p}]' <<<"$entries")"
    done
    jq . <<<"$entries" > "${dir}/artefacts.json"
    ( cd "$dir" && sha256_manifest ) > "${dir}/SHA256SUMS"
    log "solution bundle ready: ${dir} ($(du -sh "$dir" | awk '{print $1}'), ${n} artefact(s))"
    ;;

  load)
    [[ -f "${dir}/SHA256SUMS" && -f "${dir}/artefacts.json" ]] || die "not a solution bundle: ${dir}"
    step "verify bundle checksums"
    ( cd "$dir" && sha256_check SHA256SUMS ) || die "bundle checksum verification failed"
    registry_login
    refs=()
    while read -r e; do
      repo="$(jq -r .repository <<<"$e")"; digest="$(jq -r .digest <<<"$e")"
      tag="$(jq -r .tag <<<"$e")"; layout="$(jq -r .layout <<<"$e")"
      dest="${REGISTRY_HOST}/${repo}:${tag:-${digest#sha256:}}"
      log "load ${repo}@${digest} -> ${dest}"
      oras copy -r --from-oci-layout "${dir}/${layout}@${digest}" \
        --to-ca-file "$REGISTRY_CA_FILE" --to-registry-config "$REGISTRY_AUTH_FILE" "$dest" >/dev/null
      got="$(oras resolve --ca-file "$REGISTRY_CA_FILE" --registry-config "$REGISTRY_AUTH_FILE" "$dest")"
      [[ "$got" == "$digest" ]] || die "digest changed while loading ${repo}: ${got} != ${digest}"
      refs+=("${REGISTRY_HOST}/${repo}@${digest}")
    done < <(jq -c '.[]' "${dir}/artefacts.json")
    step "verify signatures with the ${ENV} platform key"
    "${REPO_ROOT}/scripts/supply-chain/sign.sh" "$ENV" verify "${refs[@]}"
    log "loaded: ${refs[*]}"
    ;;

  *) die "usage: solution.sh bundle|load <env> <dir> [refs...]" ;;
esac
