#!/usr/bin/env bash
# Mirror the OpenTofu providers of every stack into a filesystem mirror so
# `tofu init` works without registry.opentofu.org (air-gap).
#   scripts/airgap/providers-mirror.sh [out-dir]   (default: ${BOCCOB_CACHE_DIR}/tofu-provider-mirror)
# scripts/tofu.sh uses the mirror automatically when the directory is not empty.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_cmd tofu
out="${1:-${BOCCOB_CACHE_DIR}/tofu-provider-mirror}"
mkdir -p "$out"
for d in "${REPO_ROOT}"/stacks/[0-9]*/; do
  log "mirror providers of $(basename "$d")"
  TF_DATA_DIR="${BOCCOB_CACHE_DIR}/lint/$(basename "$d")" tofu -chdir="$d" providers mirror "$out" >/dev/null
done
log "provider mirror: ${out} ($(du -sh "$out" | awk '{print $1}'))"
