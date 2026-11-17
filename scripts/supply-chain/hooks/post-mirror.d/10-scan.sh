#!/usr/bin/env bash
# post-mirror hook: Trivy scan of the image now in Zot. Enabled with
# SUPPLY_CHAIN_HOOKS=1 SCAN=1 (FAIL_ON=CRITICAL makes findings blocking).
set -euo pipefail
[[ "${SCAN:-0}" == "1" ]] || exit 0
exec "$(dirname "${BASH_SOURCE[0]}")/../../scan.sh" "$1" "$IMAGE_KEY"
