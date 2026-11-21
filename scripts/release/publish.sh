#!/usr/bin/env bash
# Build, push and sign a solution release into the environment's Zot (audit R3-2).
#
#   scripts/release/publish.sh <env>        make release-publish ENV=<env>
#
# Calls the solution repository's own targets (`make image image-push bundle
# bundle-push`, interface in its docs/releases.md "Publishing") with the
# platform's registry, trust and proxy settings, then signs both artefacts with
# the OpenBao transit key (scripts/supply-chain/sign.sh). Nothing is written to
# /etc: the registry CA reaches podman/oras/cosign per call (REGISTRY_CA_FILE).
#
# Environment:
#   SOLUTION_DIR      checkout of the solution repository (default: the sibling
#                     directory ../project-boccob next to this repository)
#   VERSION           artefact version (default: the solution's 0.1.0-<git describe>)
#   REGISTRY_PASSWORD push password (default: the registry push password file of
#                     the environment, ${STATE_DIR}/registry/push-password)
#   SBOM=0            build without SBOM/scan (no image tarball: needs ~1 GB less disk);
#                     scan the pushed image later with trivy/syft
#   SKIP_BUILD=1      push only what was built before (same digests on re-push)
#   BUILD_STORAGE_ROOT=<dir>  separate podman storage (and TMPDIR) for the build, e.g.
#                     a tmpfs on a disk-constrained host; removed afterwards
#                     (the image is pushed from there, nothing stays behind)
#   BUILD_PROXY / BUILD_CA_BUNDLE / BUILD_NETWORK   default from HTTPS_PROXY and the
#                     base CA bundle when an outbound proxy is configured
#   PLATFORMS         image platform(s) to build (default: linux/<CLUSTER_ARCH>, the
#                     cluster's own). Several (linux/amd64,linux/arm64) build a
#                     multi-arch index (needs qemu-user-static for the foreign arch);
#                     the recorded and signed digest is then the index digest.
# Result: dist/image/image.ref and dist/opa/bundle.ref in SOLUTION_DIR, both signed;
# set them as dagster_code_location_image / opa_bundle_ref in the env tfvars.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
load_env "${1:-${ENV:-}}"
require_cmd make podman git

SOLUTION_DIR="${SOLUTION_DIR:-${REPO_ROOT}/../project-boccob}"
[[ -f "${SOLUTION_DIR}/Makefile" && -f "${SOLUTION_DIR}/scripts/push-image.sh" ]] \
  || die "SOLUTION_DIR=${SOLUTION_DIR} is not a checkout of the solution repository"
SOLUTION_DIR="$(cd "$SOLUTION_DIR" && pwd)"
[[ -f "$REGISTRY_CA_FILE" ]] || die "registry CA missing: ${REGISTRY_CA_FILE}"

if [[ -z "${REGISTRY_PASSWORD:-}" ]]; then
  pwfile="$(registry_push_password_file)"
  [[ -f "$pwfile" ]] || die "registry push password missing (${pwfile}); set REGISTRY_PASSWORD"
  REGISTRY_PASSWORD="$(cat "$pwfile")"
fi
export REGISTRY="$REGISTRY_HOST" REGISTRY_HOST REGISTRY_CA_FILE
export REGISTRY_USERNAME="${REGISTRY_USERNAME:-$REGISTRY_PUSH_USER}" REGISTRY_PASSWORD
[[ -n "${VERSION:-}" ]] && export VERSION
ensure_cluster_arch
export PLATFORMS="${PLATFORMS:-linux/${CLUSTER_ARCH}}"
IFS=',' read -ra _plats <<<"$PLATFORMS"
for p in "${_plats[@]}"; do
  if [[ "$p" != linux/* ]] || ! normalize_arch "${p#linux/}" >/dev/null; then
    die "PLATFORMS: ${p} is not linux/amd64 or linux/arm64"
  fi
done
[[ ",${PLATFORMS}," == *",linux/${CLUSTER_ARCH},"* ]] || warn "PLATFORMS=${PLATFORMS} does not include the cluster's linux/${CLUSTER_ARCH}"
log "image platform(s): ${PLATFORMS}"
# the image build fetches packages: through the outbound proxy, trusting its CA
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  export BUILD_PROXY="${BUILD_PROXY:-$HTTPS_PROXY}" BUILD_NETWORK="${BUILD_NETWORK:-host}"
  export BUILD_CA_BUNDLE="${BUILD_CA_BUNDLE:-${BOCCOB_BASE_CA_BUNDLE}}"
fi

if [[ -n "${BUILD_STORAGE_ROOT:-}" ]]; then
  [[ "${SKIP_BUILD:-0}" == "1" ]] && die "BUILD_STORAGE_ROOT is removed after each run: SKIP_BUILD=1 has nothing to push"
  mkdir -p "${BUILD_STORAGE_ROOT}/storage" "${BUILD_STORAGE_ROOT}/run" "${BUILD_STORAGE_ROOT}/tmp"
  printf '[storage]\ndriver = "overlay"\ngraphroot = "%s/storage"\nrunroot = "%s/run"\n' \
    "$BUILD_STORAGE_ROOT" "$BUILD_STORAGE_ROOT" > "${BUILD_STORAGE_ROOT}/storage.conf"
  export CONTAINERS_STORAGE_CONF="${BUILD_STORAGE_ROOT}/storage.conf" TMPDIR="${BUILD_STORAGE_ROOT}/tmp"
  # explicit --root/--runroot: never touches the host's own podman storage
  trap 'podman --root "${BUILD_STORAGE_ROOT}/storage" --runroot "${BUILD_STORAGE_ROOT}/run" rmi -a -f >/dev/null 2>&1 || true
        rm -rf "${BUILD_STORAGE_ROOT:?}"/{storage,run,tmp,storage.conf}' EXIT
  log "podman storage for this build: ${BUILD_STORAGE_ROOT}"
fi

targets=(image-push bundle bundle-push)
[[ "${SKIP_BUILD:-0}" == "1" ]] || targets=(image "${targets[@]}")
path="$PATH"
# the solution's build runs syft/trivy whenever they are on PATH (ours are)
[[ "${SBOM:-1}" == "0" ]] && path="$(tr ':' '\n' <<<"$PATH" | grep -vxF "${BOCCOB_CACHE_DIR}/bin" | paste -sd: -)"
step "solution ${SOLUTION_DIR} ($(git -C "$SOLUTION_DIR" rev-parse --short HEAD)): make ${targets[*]} -> ${REGISTRY} (${PLATFORMS})"
PATH="$path" make -C "$SOLUTION_DIR" "${targets[@]}"

image_ref="$(cat "${SOLUTION_DIR}/dist/image/image.ref")"
bundle_ref="$(cat "${SOLUTION_DIR}/dist/opa/bundle.ref")"
[[ "$image_ref" == "${REGISTRY}/"*@sha256:* && "$bundle_ref" == "${REGISTRY}/"*@sha256:* ]] \
  || die "unexpected artefact references: ${image_ref} ${bundle_ref}"

step "sign with the platform key"
"${REPO_ROOT}/scripts/supply-chain/sign.sh" "$ENV" sign "$image_ref" "$bundle_ref"
"${REPO_ROOT}/scripts/supply-chain/sign.sh" "$ENV" verify "$image_ref" "$bundle_ref"

if [[ "${KEEP_LOCAL_IMAGE:-0}" != "1" && "${SKIP_BUILD:-0}" != "1" ]]; then
  tag="$(cat "${SOLUTION_DIR}/dist/image/image.tag")"
  # a multi-platform build leaves a manifest list plus one image per platform (image.local)
  podman manifest rm "$tag" >/dev/null 2>&1 || true
  if [[ -f "${SOLUTION_DIR}/dist/image/image.local" ]]; then
    while read -r img; do podman rmi "$img" >/dev/null 2>&1 || true; done < "${SOLUTION_DIR}/dist/image/image.local"
  else
    podman rmi "$tag" >/dev/null 2>&1 || true
  fi
fi
log "published and signed:"
printf 'dagster_code_location_image = "%s"\nopa_bundle_ref              = "%s"\n' "$image_ref" "$bundle_ref"
