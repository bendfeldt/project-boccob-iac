#!/usr/bin/env bash
# pre-mirror hook: verify the upstream signature before an image enters Zot.
# Enabled with SUPPLY_CHAIN_HOOKS=1 VERIFY_SIGNATURES=1. Environment from
# mirror.sh: IMAGE_KEY, IMAGE_UPSTREAM_REF, IMAGE_INDEX_DIGEST, IMAGE_ZOT_REF.
set -euo pipefail
[[ "${VERIFY_SIGNATURES:-0}" == "1" ]] || exit 0
exec "$(dirname "${BASH_SOURCE[0]}")/../../verify-signatures.sh" "$1" "$IMAGE_KEY"
