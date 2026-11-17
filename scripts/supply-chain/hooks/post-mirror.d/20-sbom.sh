#!/usr/bin/env bash
# post-mirror hook: SBOM of the image now in Zot. Enabled with
# SUPPLY_CHAIN_HOOKS=1 SBOM=1 (ATTEST=1 + COSIGN_KEY attaches it as attestation).
set -euo pipefail
[[ "${SBOM:-0}" == "1" ]] || exit 0
exec "$(dirname "${BASH_SOURCE[0]}")/../../sbom.sh" "$1" "$IMAGE_KEY"
