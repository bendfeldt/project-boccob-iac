#!/usr/bin/env bash
# Self-check of scripts/lib/destroy-guard.jq (the deploy guard) against a fixture plan:
# exactly the irreplaceable deletes/replaces are reported, nothing harmless.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
d="${REPO_ROOT}/scripts/tests"
want='kubernetes_persistent_volume_claim_v1.data (delete)
module.keycloak_db.kubernetes_manifest.cluster (delete)
module.ns_database.kubernetes_namespace_v1.this (delete)
module.rustfs.helm_release.this (create+delete)
vault_mount.kv (delete+create)'
got="$(jq -r -f "${REPO_ROOT}/scripts/lib/destroy-guard.jq" "${d}/fixtures/destroy-guard-plan.json" | sort)"
[[ "$got" == "$want" ]] || die "destroy guard: got"$'\n'"${got}"$'\n'"want"$'\n'"${want}"
log "destroy guard: OK"
