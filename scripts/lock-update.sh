#!/usr/bin/env bash
# Resolve versions.yaml -> versions.lock.yaml (digests + checksums).
# Needs internet (run on the connected workstation).
#
#   scripts/lock-update.sh            resolve what changed (REUSE=1, default)
#   REUSE=0 scripts/lock-update.sh    resolve everything again
#
# Images: one manifest digest per platform of `platforms:` (linux/amd64,
# linux/arm64), taken from the upstream index (manifest list). The index digest is
# kept as well (signatures, provenance). When an entry's source/tag are unchanged
# the index already in the lock is re-read BY DIGEST, so adding a platform never
# moves the digests of the platforms that were locked before (tags move upstream).
# A platform an image does not publish is listed under `missing_platforms` and
# reported at the end; nothing is guessed.
#
# Binaries: sha256 per platform from the upstream checksum file (`checksums:`), or
# of the download itself where upstream publishes none.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd skopeo helm jq yq curl

REUSE="${REUSE:-1}"
want="$(yq -c . "$VERSIONS_FILE")"
old='{}'
[[ -f "$LOCK_FILE" && "$REUSE" == "1" ]] && old="$(yq -c . "$LOCK_FILE")"

mapfile -t platforms < <(jq -r '.platforms[]' <<<"$want")
[[ ${#platforms[@]} -gt 0 ]] || die "versions.yaml: platforms is empty"
for p in "${platforms[@]}"; do
  [[ "$p" == linux/* ]] || die "versions.yaml: platform ${p}: only linux/* cluster platforms"
  [[ "$(normalize_arch "${p#linux/}" || true)" == "${p#linux/}" ]] || die "versions.yaml: platform ${p} is not supported (linux/amd64, linux/arm64)"
done
arches_json="$(printf '%s\n' "${platforms[@]}" | sed 's|^linux/||' | jq -R . | jq -sc .)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
gaps=()

# digest_for <index.json> <arch> -> manifest digest of linux/<arch> (variant v8 or none for arm64)
digest_for() {
  jq -r --arg arch "$2" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch
       and ((.platform.variant // "") as $v | $arch != "arm64" or $v == "" or $v == "v8"))][0].digest // ""' "$1"
}

images='{}'
while read -r key; do
  src="$(jq -r --arg k "$key" '.images[$k].source' <<<"$want")"
  tag="$(jq -r --arg k "$key" '.images[$k].tag' <<<"$want")"
  groups="$(jq -c --arg k "$key" '.images[$k].groups // []' <<<"$want")"
  prev="$(jq -c --arg k "$key" '.images[$k] // {}' <<<"$old")"
  same=false
  [[ "$(jq -r '"\(.source // "")|\(.tag // "")"' <<<"$prev")" == "${src}|${tag}" ]] && same=true
  # complete previous entry for exactly these platforms: keep it
  if $same && jq -e --argjson a "$arches_json" '(.digests // {}) as $d | (.missing_platforms // []) as $m
        | all($a[]; (($d[.] // "") | startswith("sha256:")) or ($m | index(.) != null))' <<<"$prev" >/dev/null; then
    images="$(jq -c --arg k "$key" --argjson p "$prev" --argjson g "$groups" '.[$k] = ($p + {groups: $g})' <<<"$images")"
    while read -r m; do [[ -n "$m" ]] && gaps+=("${key} (${src}:${tag}): no linux/${m}"); done < <(jq -r '.missing_platforms[]?' <<<"$prev")
    continue
  fi
  prev_index="$(jq -r '.index_digest // ""' <<<"$prev")"
  if $same && [[ "$prev_index" == sha256:* ]]; then
    log "resolve image ${src}:${tag} (locked index ${prev_index:7:12})"
    ref="docker://${src}@${prev_index}"
  else
    log "resolve image ${src}:${tag}"
    ref="docker://${src}:${tag}"
  fi
  skopeo inspect --raw "$ref" > "${tmp}/raw.json"
  top="sha256:$(sha256_of "${tmp}/raw.json")"
  digests='{}'; missing='[]'; index_digest=""
  if jq -e '.manifests' "${tmp}/raw.json" >/dev/null; then
    index_digest="$top"
    for p in "${platforms[@]}"; do
      a="${p#linux/}"; d="$(digest_for "${tmp}/raw.json" "$a")"
      if [[ -n "$d" ]]; then digests="$(jq -c --arg a "$a" --arg d "$d" '.[$a] = $d' <<<"$digests")"
      else missing="$(jq -c --arg a "$a" '. + [$a]' <<<"$missing")"; gaps+=("${key} (${src}:${tag}): no ${p}"); fi
    done
  else
    # single-platform image: its config says which platform it is
    a="$(skopeo inspect --config "docker://${src}@${top}" | jq -r '.architecture')"
    a="$(normalize_arch "$a" || echo "$a")"
    for p in "${platforms[@]}"; do
      if [[ "${p#linux/}" == "$a" ]]; then digests="$(jq -c --arg a "$a" --arg d "$top" '.[$a] = $d' <<<"$digests")"
      else missing="$(jq -c --arg a "${p#linux/}" '. + [$a]' <<<"$missing")"; gaps+=("${key} (${src}:${tag}): single-platform image (${a}), no ${p}"); fi
    done
  fi
  # the digest a running cluster uses must not move silently (lock written before per-arch digests)
  prev_amd64="$(jq -r '.digests.amd64 // .digest // ""' <<<"$prev")"
  if $same && [[ -n "$prev_amd64" && "$prev_amd64" != "$(jq -r '.amd64 // ""' <<<"$digests")" ]]; then
    die "image ${key}: linux/amd64 digest would change (${prev_amd64} -> $(jq -r '.amd64 // "none"' <<<"$digests")); REUSE=0 to accept a new upstream index"
  fi
  images="$(jq -c --arg k "$key" --arg s "$src" --arg t "$tag" --arg i "$index_digest" \
      --argjson d "$digests" --argjson m "$missing" --argjson g "$groups" '
    .[$k] = ({source: $s, tag: $t} + (if $i != "" then {index_digest: $i} else {} end)
             + {digests: $d} + (if ($m | length) > 0 then {missing_platforms: $m} else {} end) + {groups: $g})' <<<"$images")"
done < <(jq -r '.images | keys_unsorted[]' <<<"$want")

charts='{}'
while read -r key; do
  repo="$(jq -r --arg k "$key" '.charts[$k].repo' <<<"$want")"
  name="$(jq -r --arg k "$key" '.charts[$k].name' <<<"$want")"
  ver="$(jq -r --arg k "$key" '.charts[$k].version' <<<"$want")"
  groups="$(jq -c --arg k "$key" '.charts[$k].groups // []' <<<"$want")"
  prev="$(jq -c --arg k "$key" '.charts[$k] // {}' <<<"$old")"
  if [[ "$(jq -r '"\(.repo)|\(.name)|\(.version)"' <<<"$prev")" == "${repo}|${name}|${ver}" \
        && -n "$(jq -r '.sha256 // ""' <<<"$prev")" ]]; then
    sum="$(jq -r '.sha256' <<<"$prev")"
  else
    log "resolve chart ${name} ${ver} (${repo})"
    rm -rf "${tmp}/chart"; mkdir -p "${tmp}/chart"
    if [[ "$repo" == oci://* ]]; then
      helm pull "${repo}/${name}" --version "$ver" -d "${tmp}/chart" >/dev/null
    else
      helm pull "$name" --repo "$repo" --version "$ver" -d "${tmp}/chart" >/dev/null
    fi
    sum="$(sha256_of "${tmp}/chart/"*.tgz)"
  fi
  charts="$(jq -c --arg k "$key" --arg r "$repo" --arg n "$name" --arg v "$ver" --arg s "$sum" --argjson g "$groups" \
    '.[$k] = {repo: $r, name: $n, version: $v, sha256: $s, groups: $g}' <<<"$charts")"
done < <(jq -r '.charts | keys_unsorted[]' <<<"$want")

# checksum_from <checksums-url> <file name> -> sha256 listed upstream for that file
checksum_from() {
  local url="$1" name="$2" f sum
  f="${tmp}/sums-$(printf '%s' "$url" | sha256_stream | cut -c1-16)"
  [[ -f "$f" ]] || curl -fsSL --retry 3 -o "$f" "$url" || die "cannot download checksum file ${url}"
  sum="$(awk -v n="$name" '$2 == n || $2 == "*"n || $2 == "./"n {print $1}' "$f" | head -n1)"
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "no sha256 for ${name} in ${url}"
  printf '%s' "$sum"
}

binaries='{}'
while read -r key; do
  entry="$(jq -c --arg k "$key" '.binaries[$k]' <<<"$want")"
  plats='{}'
  while read -r p; do
    pe="$(jq -c --arg p "$p" '.platforms[$p]' <<<"$entry")"
    url="$(jq -r '.url' <<<"$pe")"; csums="$(jq -r '.checksums // ""' <<<"$pe")"
    base="$(basename "${url%%\?*}")"; base="${base//%2B/+}"
    file="$(jq -r --arg b "$base" '.file // $b' <<<"$pe")"
    prev="$(jq -c --arg k "$key" --arg p "$p" '.binaries[$k].platforms[$p] // {}' <<<"$old")"
    if [[ "$(jq -r '.url // ""' <<<"$prev")" == "$url" && "$(jq -r '.sha256 // ""' <<<"$prev")" =~ ^[0-9a-f]{64}$ ]]; then
      sum="$(jq -r '.sha256' <<<"$prev")"
    elif [[ -n "$csums" ]]; then
      log "checksum ${key} ${p} (${csums##*/})"
      sum="$(checksum_from "$csums" "$base")"
    else
      dest="${BOCCOB_CACHE_DIR}/downloads/${key}/${file}"
      rm -f "$dest"
      fetch_verified "$url" "$dest" ""
      sum="$(sha256_of "$dest")"
    fi
    plats="$(jq -c --arg p "$p" --arg u "$url" --arg f "$file" --arg s "$sum" --arg c "$csums" \
      '.[$p] = ({url: $u, file: $f, sha256: $s} + (if $c != "" then {checksums: $c} else {} end))' <<<"$plats")"
  done < <(jq -r '.platforms | keys_unsorted[]' <<<"$entry")
  binaries="$(jq -c --arg k "$key" --argjson e "$entry" --argjson p "$plats" \
    '.[$k] = (($e | del(.platforms)) + {platforms: $p})' <<<"$binaries")"
done < <(jq -r '.binaries | keys_unsorted[]' <<<"$want")

{
  cat <<'HDR'
# versions.lock.yaml — GENERATED by `make lock` from versions.yaml. Do not edit by hand.
# Single source of truth for every pinned image (one linux manifest digest per
# platform + the upstream index digest), Helm chart (tgz sha256) and downloaded
# binary (sha256 per platform) used by this platform.
HDR
  jq -n --argjson w "$want" --argjson i "$images" --argjson c "$charts" --argjson b "$binaries" \
    '{platforms: $w.platforms, k3s: $w.k3s, images: $i, charts: $c, binaries: $b}' | yq -y .
} > "${LOCK_FILE}.tmp"
mv "${LOCK_FILE}.tmp" "$LOCK_FILE"
log "wrote ${LOCK_FILE}: $(jq 'length' <<<"$images") images x ${#platforms[@]} platforms, $(jq 'length' <<<"$charts") charts, $(jq 'length' <<<"$binaries") binaries"
if [[ ${#gaps[@]} -gt 0 ]]; then
  warn "platforms not published upstream (see docs/versions.md for the alternatives):"
  for g in "${gaps[@]}"; do warn "  ${g}"; done
else
  log "every image publishes all of: ${platforms[*]}"
fi
