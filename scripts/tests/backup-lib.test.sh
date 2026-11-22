#!/usr/bin/env bash
# Self-check of scripts/backup/lib.sh without a cluster (run by make lint):
# S3 listing across pages, newest snapshot, snapshot age without GNU date.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../backup/lib.sh
source "${REPO_ROOT}/scripts/backup/lib.sh"

# fake ListObjectsV2: 2500 hourly snapshots (+ .sha256) in pages of 1000 keys
all="$(jq -rn 'range(0; 2500) | "openbao/raft-\(1700000000 + . * 3600 | strftime("%Y%m%dT%H%M%SZ")).snap" | ., "\(.).sha256"')"
s3_curl() {
  local start=0 n
  [[ "$1" == *continuation-token=* ]] && start="${1##*continuation-token=}"
  n="$(wc -l <<<"$all")"
  printf '<ListBucketResult>'
  sed -n "$((start + 1)),$((start + 1000))p" <<<"$all" | sed 's#.*#<Key>&</Key>#' | tr -d '\n'
  if (( start + 1000 < n )); then
    printf '<IsTruncated>true</IsTruncated><NextContinuationToken>%s</NextContinuationToken>' $((start + 1000))
  else printf '<IsTruncated>false</IsTruncated>'; fi
  printf '</ListBucketResult>'
}

fail=0
got="$(s3_keys "openbao/" | wc -l | tr -d ' ')"
[[ "$got" == 5000 ]] || { err "s3_keys returned ${got} keys, want 5000"; fail=1; }
want="openbao/raft-$(jq -rn --argjson t $((1700000000 + 2499 * 3600)) '$t | strftime("%Y%m%dT%H%M%SZ")').snap"
got="$(openbao_latest_snapshot)"
[[ "$got" == "$want" ]] || { err "openbao_latest_snapshot: ${got}, want ${want}"; fail=1; }
got="$(snapshot_epoch "$want")"
[[ "$got" == $((1700000000 + 2499 * 3600)) ]] || { err "snapshot_epoch: ${got}"; fail=1; }
(( fail == 0 )) && log "backup lib: OK"
exit "$fail"
