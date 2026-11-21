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
#   MIRROR_ARCHES=amd64,arm64          image architectures to copy (default: CLUSTER_ARCH, the
#                                      cluster's own; amd64 = x64/x86_64, arm64 = aarch64)
#   SUPPLY_CHAIN_HOOKS=1               run scripts/supply-chain/hooks/{pre,post}-mirror.d/*.sh per image
#   TAR=1                              (bundle) also write <dir>.tar
#
# Images are copied with skopeo --preserve-digests: the manifest digest in Zot
# is byte-identical to the locked upstream digest (podman pull/push would
# re-compress layers and change it). One single-platform manifest per
# architecture is copied, never the whole upstream index: skopeo can copy one
# platform, all platforms or the bare index, and "all" would also bring
# arm/v7, ppc64le, s390x, ... (2-6x the bytes). Workloads reference the
# per-arch manifest digest (modules/versions, var.arch), so no index is needed.
# Zot tags: <tag> = the cluster's own architecture (k3s pulls its system images
# by tag), <tag>-<arch> = any additional architecture in MIRROR_ARCHES.
# Bundles keep images per architecture: images/<arch>/<key>.tar.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"

cmd="${1:-}"; shift || true
load_env "${1:-${ENV:-}}"; shift || true
require_cmd skopeo helm jq yq curl
MIRROR_GROUPS="${MIRROR_GROUPS:-}"
ensure_cluster_arch
arches=()
IFS=',' read -ra _req <<<"${MIRROR_ARCHES:-$CLUSTER_ARCH}"
for a in "${_req[@]}"; do
  [[ -n "$a" ]] && arches+=("$(arch_or_die "$a" "MIRROR_ARCHES")")
done
[[ ${#arches[@]} -gt 0 ]] || die "MIRROR_ARCHES is empty"
log "image architectures: ${arches[*]} (cluster: ${CLUSTER_ARCH})"

run_hooks() {
  # run_hooks <stage> <image-key> <arch>
  [[ "${SUPPLY_CHAIN_HOOKS:-0}" == "1" ]] || return 0
  local stage="$1" key="$2" arch="$3" hook
  for hook in "${REPO_ROOT}/scripts/supply-chain/hooks/${stage}.d/"*.sh; do
    [[ -x "$hook" ]] || continue
    IMAGE_KEY="$key" IMAGE_ARCH="$arch" \
    IMAGE_UPSTREAM_REF="$(image_upstream_ref "$key" "$arch")" \
    IMAGE_INDEX_DIGEST="$(lock_q '.images[$k].index_digest // ""' --arg k "$key")" \
    IMAGE_ZOT_REF="$(image_zot_ref "$key" "$arch")" \
      "$hook" "$ENV" || die "hook $(basename "$hook") failed for image ${key} (${arch})"
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
  # image_in_registry <key> <arch>: true when <source>:<zot tag> in Zot resolves to the locked digest
  local key="$1" arch="$2" src got
  src="$(lock_q '.images[$k].source' --arg k "$key")"
  got="$(curl -fsS -o /dev/null -I -w '%header{docker-content-digest}' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://${REGISTRY_HOST}/v2/${src}/manifests/$(image_zot_tag "$key" "$arch")" 2>/dev/null || true)"
  [[ "$got" == "$(image_digest "$key" "$arch")" ]]
}

# bundle_image_file <bundle dir> <key> <arch>
bundle_image_file() { printf '%s/images/%s/%s.tar' "$1" "$3" "$2"; }

sync_images() {
  # sync_images <from: upstream|bundle-dir>
  local from="$1" key src tag arch dst f
  while read -r key; do
    src="$(lock_q '.images[$k].source' --arg k "$key")"
    for arch in "${arches[@]}"; do
      tag="$(image_zot_tag "$key" "$arch")"
      dst="docker://${REGISTRY_HOST}/${src}:${tag}"
      if image_in_registry "$key" "$arch"; then
        log "image ${src}:${tag} (${arch}) already in registry"
      else
        if [[ "$from" == "upstream" ]]; then
          run_hooks pre-mirror "$key" "$arch"
          log "copy ${src}:${tag} (linux/${arch})"
          skopeo_copy "docker://$(image_upstream_ref "$key" "$arch")" "$dst"
        else
          f="$(bundle_image_file "$from" "$key" "$arch")"
          [[ -f "$f" ]] || die "bundle has no linux/${arch} image ${key} (${f#"${from}/"}); build it with MIRROR_ARCHES=${arch}"
          log "load ${src}:${tag} (linux/${arch})"
          skopeo_copy "oci-archive:${f}" "$dst"
        fi
        image_in_registry "$key" "$arch" || die "digest mismatch after copying ${src}:${tag}"
      fi
      run_hooks post-mirror "$key" "$arch"
    done
  done < <(lock_keys images "$MIRROR_GROUPS")
}

# bundle_binary_platforms <key>: platforms of a binary that go into a bundle:
# platform-independent files, linux/<arch> for every MIRROR_ARCHES entry, and
# this machine's platform plus BUNDLE_TOOL_PLATFORMS (e.g. darwin/arm64) for tools
bundle_binary_platforms() {
  local key="$1" p a extra="${BUNDLE_TOOL_PLATFORMS:-}" want
  want=" any $(host_platform) ${extra//,/ } "
  for a in "${arches[@]}"; do want+="linux/${a} "; done
  while read -r p; do
    [[ "$want" == *" ${p} "* ]] && printf '%s\n' "$p"
  done < <(lock_q '.binaries[$k].platforms | keys[]' --arg k "$key")
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
    step "bundle images -> ${out}/images (groups: ${MIRROR_GROUPS:-all}; linux/${arches[*]})"
    while read -r key; do
      for arch in "${arches[@]}"; do
        f="$(bundle_image_file "$out" "$key" "$arch")"
        mkdir -p "$(dirname "$f")"
        if [[ -f "$f" && -f "${f}.digest" && "$(cat "${f}.digest")" == "$(image_digest "$key" "$arch")" ]]; then
          log "image ${key} (${arch}) already bundled"; continue
        fi
        run_hooks pre-mirror "$key" "$arch"
        log "save $(image_upstream_ref "$key" "$arch")"
        rm -f "$f"
        skopeo copy --quiet --preserve-digests --retry-times 3 "docker://$(image_upstream_ref "$key" "$arch")" "oci-archive:${f}"
        image_digest "$key" "$arch" > "${f}.digest"
      done
    done < <(lock_keys images "$MIRROR_GROUPS")
    step "bundle charts"
    while read -r key; do chart_fetch "$key" "${out}/charts" >/dev/null; done < <(lock_keys charts "$MIRROR_GROUPS")
    step "bundle binaries"
    while read -r key; do
      while read -r p; do
        fetch_verified "$(binary_field "$key" "$p" url)" "${out}/binaries/$(binary_field "$key" "$p" file)" \
          "$(binary_field "$key" "$p" sha256)"
      done < <(bundle_binary_platforms "$key")
    done < <(lock_keys binaries "$MIRROR_GROUPS")
    cp "$LOCK_FILE" "${out}/versions.lock.yaml"
    ( cd "$out" && sha256_manifest ) > "${out}/SHA256SUMS.tmp"
    mv "${out}/SHA256SUMS.tmp" "${out}/SHA256SUMS"
    log "bundle ready: ${out} ($(du -sh "$out" | awk '{print $1}'))"
    if [[ "${TAR:-0}" == "1" ]]; then
      tar -C "$(dirname "$out")" -cf "${out}.tar" "$(basename "$out")"
      ( cd "$(dirname "$out")" && sha256_stream "$(basename "$out").tar" ) > "${out}.tar.sha256"
      log "transfer ${out}.tar (+ .sha256) to the air-gapped side"
    fi
    ;;

  load)
    from="${1:?usage: mirror.sh load <env> <bundle-dir>}"
    [[ -f "${from}/SHA256SUMS" ]] || die "not a bundle directory: ${from}"
    step "verify bundle checksums"
    ( cd "$from" && sha256_check SHA256SUMS ) || die "bundle checksum verification failed"
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
      for arch in "${arches[@]}"; do
        image_in_registry "$key" "$arch" || { err "missing or wrong digest: image ${key} (linux/${arch})"; rc=1; }
      done
    done < <(lock_keys images "$MIRROR_GROUPS")
    while read -r key; do
      name="$(lock_q '.charts[$k].name' --arg k "$key")"; ver="$(lock_q '.charts[$k].version' --arg k "$key")"
      registry_has_manifest "charts/${name}" "${ver//+/_}" || { err "missing chart ${name}:${ver}"; rc=1; }
    done < <(lock_keys charts "$MIRROR_GROUPS")
    [[ $rc -eq 0 ]] && log "registry ${REGISTRY_HOST} holds every locked image (linux/${arches[*]}) and chart (groups: ${MIRROR_GROUPS:-all})"
    exit $rc
    ;;

  *) die "usage: mirror.sh sync|bundle|load|check <env> [dir]" ;;
esac
