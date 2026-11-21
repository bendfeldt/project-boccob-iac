#!/usr/bin/env bash
# Zot registry helpers (auth, CA, skopeo/helm wrappers).
# shellcheck shell=bash

REGISTRY_PUSH_USER="${REGISTRY_PUSH_USER:-mirror}"

registry_push_password_file() { printf '%s' "${STATE_DIR}/registry/push-password"; }

# registry_login: writes a containers-auth.json usable by skopeo, podman, helm, cosign and trivy
registry_login() {
  local pwfile; pwfile="$(registry_push_password_file)"
  [[ -f "$pwfile" ]] || die "registry push password missing (${pwfile}); run cluster-up / registry-up first, or place it there"
  local auth; auth="$(printf '%s:%s' "$REGISTRY_PUSH_USER" "$(cat "$pwfile")" | b64_nowrap)"
  jq -n --arg h "$REGISTRY_HOST" --arg a "$auth" '{auths: {($h): {auth: $a}}}' | write_secret_file "$REGISTRY_AUTH_FILE"
  export REGISTRY_AUTH_FILE
}

registry_ready() { curl -fsS -o /dev/null "https://${REGISTRY_HOST}/v2/"; }

# registry_has_manifest <repo-path> <tag-or-digest>
registry_has_manifest() {
  curl -fsS -o /dev/null -I \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://${REGISTRY_HOST}/v2/$1/manifests/$2" 2>/dev/null
}

# skopeo_copy <src> <dst> : digest-preserving copy of ONE platform image
skopeo_copy() {
  skopeo copy --quiet --preserve-digests --retry-times 3 \
    --authfile "$REGISTRY_AUTH_FILE" "$@"
}
