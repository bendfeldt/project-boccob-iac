#!/usr/bin/env bash
# Air-gap mirroring driven by versions.lock.yaml.
#
#   mirror.sh sync   <env>            connected: upstream -> Zot (images by digest, charts as OCI)
#   mirror.sh bundle <env> [dir]      connected: upstream -> transferable bundle dir (+ .tar with TAR=1)
#   mirror.sh load   <env> <dir>      air-gapped: bundle dir -> Zot
#   mirror.sh check  <env>            verify every locked image/chart is present in Zot with the locked digest
#
# Environment:
#   MIRROR_GROUPS=cluster,foundation   only entries tagged with one of these groups (default: all)
#   SUPPLY_CHAIN_HOOKS=1               run scripts/supply-chain/hooks/{pre,post}-mirror.d/*.sh per image
#   TAR=1                              (bundle) also write <dir>.tar
#
# Images are copied with skopeo --preserve-digests: the manifest digest in Zot
# is byte-identical to the locked upstream digest (podman pull/push would
# re-compress layers and change it). Only the locked platform is mirrored.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"

cmd="${1:-}"; shift || true
load_env "${1:-${ENV:-}}"; shift || true
require_cmd skopeo helm jq yq curl sha256sum
MIRROR_GROUPS="${MIRROR_GROUPS:-}"

run_hooks() {
  # run_hooks <stage> <image-key>
  [[ "${SUPPLY_CHAIN_HOOKS:-0}" == "1" ]] || return 0
  local stage="$1" key="$2" hook
  for hook in "${REPO_ROOT}/scripts/supply-chain/hooks/${stage}.d/"*.sh; do
    [[ -x "$hook" ]] || continue
    IMAGE_KEY="$key" \
    IMAGE_UPSTREAM_REF="$(image_upstream_ref "$key")" \
    IMAGE_INDEX_DIGEST="$(lock_q '.images[$k].index_digest // ""' --arg k "$key")" \
    IMAGE_ZOT_REF="$(image_zot_ref "$key")" \
      "$hook" "$ENV" || die "hook $(basename "$hook") failed for image ${key}"
  done
}

chart_fetch() {
  # chart_fetch <key> <dest-dir> -> prints tgz path, verifies sha256 from the lock
  local key="$1" dest="$2" repo name ver sum f
  repo="$(lock_q '.charts[$k].repo' --arg k "$key")"
  name="$(lock_q '.charts[$k].name' --arg k "$key")"
  ver="$(lock_q '.charts[$k].version' --arg k "$key")"
  sum="$(lock_q '.charts[$k].sha256' --arg k "$key")"
  f="${dest}/${name}-${ver}.tgz"
  if [[ ! -f "$f" || "$(sha256_of "$f")" != "$sum" ]]; then
    rm -f "$f"; mkdir -p "$dest"
    if [[ "$repo" == oci://* ]]; then
      helm pull "${repo}/${name}" --version "$ver" -d "$dest" >/dev/null
    else
      helm pull "$name" --repo "$repo" --version "$ver" -d "$dest" >/dev/null
    fi
  fi
  [[ "$(sha256_of "$f")" == "$sum" ]] || die "chart ${name}-${ver}: sha256 differs from the lock file"
  printf '%s' "$f"
}

chart_push() {
  # chart_push <key> <tgz>
  local key="$1" tgz="$2" name ver
  name="$(lock_q '.charts[$k].name' --arg k "$key")"
  ver="$(lock_q '.charts[$k].version' --arg k "$key")"
  if registry_has_manifest "charts/${name}" "${ver//+/_}"; then
    log "chart ${name}:${ver} already in registry"
  else
    log "push chart ${name}:${ver}"
    helm push "$tgz" "oci://${REGISTRY_HOST}/charts" >/dev/null 2>&1 || die "helm push failed for ${name}:${ver}"
  fi
}

image_in_registry() {
  # true when <source>:<tag> in Zot resolves to the locked digest
  local key="$1" src tag digest got
  src="$(lock_q '.images[$k].source' --arg k "$key")"
  tag="$(lock_q '.images[$k].tag' --arg k "$key")"
  digest="$(lock_q '.images[$k].digest' --arg k "$key")"
  got="$(curl -fsS -o /dev/null -I -w '%header{docker-content-digest}' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://${REGISTRY_HOST}/v2/${src}/manifests/${tag}" 2>/dev/null || true)"
  [[ "$got" == "$digest" ]]
}

sync_images() {
  # sync_images <from: upstream|bundle-dir>
  local from="$1" key src tag
  while read -r key; do
    src="$(lock_q '.images[$k].source' --arg k "$key")"
    tag="$(lock_q '.images[$k].tag' --arg k "$key")"
    if image_in_registry "$key"; then
      log "image ${src}:${tag} already in registry"
    else
      if [[ "$from" == "upstream" ]]; then
        run_hooks pre-mirror "$key"
        log "copy ${src}:${tag}"
        skopeo_copy "docker://$(image_upstream_ref "$key")" "docker://${REGISTRY_HOST}/${src}:${tag}"
      else
        [[ -f "${from}/images/${key}.tar" ]] || die "bundle is missing images/${key}.tar"
        log "load ${src}:${tag}"
        skopeo_copy "oci-archive:${from}/images/${key}.tar" "docker://${REGISTRY_HOST}/${src}:${tag}"
      fi
      image_in_registry "$key" || die "digest mismatch after copying ${src}:${tag}"
    fi
    run_hooks post-mirror "$key"
  done < <(lock_keys images "$MIRROR_GROUPS")
}

case "$cmd" in
  sync)
    registry_login
    registry_ready || die "registry https://${REGISTRY_HOST} not reachable"
    step "mirror images -> ${REGISTRY_HOST} (groups: ${MIRROR_GROUPS:-all})"
    sync_images upstream
    step "mirror charts -> oci://${REGISTRY_HOST}/charts"
    while read -r key; do
      chart_push "$key" "$(chart_fetch "$key" "${BOCCOB_CACHE_DIR}/charts")"
    done < <(lock_keys charts "$MIRROR_GROUPS")
    ;;

  bundle)
    out="${1:-${BOCCOB_CACHE_DIR}/bundle}"
    mkdir -p "${out}/images" "${out}/charts" "${out}/binaries"
    step "bundle images -> ${out}/images (groups: ${MIRROR_GROUPS:-all})"
    while read -r key; do
      f="${out}/images/${key}.tar"
      if [[ -f "$f" && -f "${f}.digest" && "$(cat "${f}.digest")" == "$(lock_q '.images[$k].digest' --arg k "$key")" ]]; then
        log "image ${key} already bundled"; continue
      fi
      run_hooks pre-mirror "$key"
      log "save $(image_upstream_ref "$key")"
      rm -f "$f"
      skopeo copy --quiet --preserve-digests --retry-times 3 "docker://$(image_upstream_ref "$key")" "oci-archive:${f}"
      lock_q '.images[$k].digest' --arg k "$key" > "${f}.digest"
    done < <(lock_keys images "$MIRROR_GROUPS")
    step "bundle charts"
    while read -r key; do chart_fetch "$key" "${out}/charts" >/dev/null; done < <(lock_keys charts "$MIRROR_GROUPS")
    step "bundle binaries"
    while read -r key; do
      fetch_verified "$(lock_q '.binaries[$k].url' --arg k "$key")" \
        "${out}/binaries/$(lock_q '.binaries[$k].file' --arg k "$key")" \
        "$(lock_q '.binaries[$k].sha256' --arg k "$key")"
    done < <(lock_keys binaries "$MIRROR_GROUPS")
    cp "$LOCK_FILE" "${out}/versions.lock.yaml"
    sums="$(cd "$out" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum)"
    printf '%s\n' "$sums" > "${out}/SHA256SUMS"
    log "bundle ready: ${out} ($(du -sh "$out" | awk '{print $1}'))"
    if [[ "${TAR:-0}" == "1" ]]; then
      tar -C "$(dirname "$out")" -cf "${out}.tar" "$(basename "$out")"
      sha256sum "${out}.tar" > "${out}.tar.sha256"
      log "transfer ${out}.tar (+ .sha256) to the air-gapped side"
    fi
    ;;

  load)
    from="${1:?usage: mirror.sh load <env> <bundle-dir>}"
    [[ -f "${from}/SHA256SUMS" ]] || die "not a bundle directory: ${from}"
    step "verify bundle checksums"
    ( cd "$from" && sha256sum --quiet -c SHA256SUMS ) || die "bundle checksum verification failed"
    cmp -s "${from}/versions.lock.yaml" "$LOCK_FILE" || die "bundle was built from a different versions.lock.yaml than this checkout"
    registry_login
    registry_ready || die "registry https://${REGISTRY_HOST} not reachable"
    step "load images -> ${REGISTRY_HOST}"
    sync_images "$from"
    step "load charts"
    while read -r key; do
      name="$(lock_q '.charts[$k].name' --arg k "$key")"; ver="$(lock_q '.charts[$k].version' --arg k "$key")"
      tgz="${from}/charts/${name}-${ver}.tgz"
      [[ "$(sha256_of "$tgz")" == "$(lock_q '.charts[$k].sha256' --arg k "$key")" ]] || die "chart ${name}-${ver}: sha256 differs from the lock file"
      chart_push "$key" "$tgz"
    done < <(lock_keys charts "$MIRROR_GROUPS")
    ;;

  check)
    rc=0
    while read -r key; do
      image_in_registry "$key" || { err "missing or wrong digest: image ${key}"; rc=1; }
    done < <(lock_keys images "$MIRROR_GROUPS")
    while read -r key; do
      name="$(lock_q '.charts[$k].name' --arg k "$key")"; ver="$(lock_q '.charts[$k].version' --arg k "$key")"
      registry_has_manifest "charts/${name}" "${ver//+/_}" || { err "missing chart ${name}:${ver}"; rc=1; }
    done < <(lock_keys charts "$MIRROR_GROUPS")
    [[ $rc -eq 0 ]] && log "registry ${REGISTRY_HOST} holds every locked image and chart (groups: ${MIRROR_GROUPS:-all})"
    exit $rc
    ;;

  *) die "usage: mirror.sh sync|bundle|load|check <env> [dir]" ;;
esac
