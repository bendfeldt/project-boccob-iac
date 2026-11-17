# shellcheck shell=bash
# Helpers shared by scripts/backup/*.sh (sourced after scripts/lib/common.sh + load_env).

BACKUP_NS="${BACKUP_NS:-backup}"
DB_NS="${DB_NS:-database}"
BACKUP_BUCKET="${BACKUP_BUCKET:-platform-backup}"
_S3_PF_PID=""
S3_LOCAL_PORT="${S3_LOCAL_PORT:-19000}"
S3_HOST="rustfs-svc.storage.svc"

# s3_session <workdir>: port-forward to RustFS, CA + credentials of the S3 user
# platform-backup (from the Secret in namespace backup) into 0600 files.
s3_session() {
  local dir="$1"
  kubectl -n platform-system get configmap platform-ca -o jsonpath='{.data.ca\.crt}' > "${dir}/ca.crt"
  local ak sk
  ak="$(kubectl -n "$BACKUP_NS" get secret platform-backup-s3 -o jsonpath='{.data.access_key_id}' | base64 -d)"
  sk="$(kubectl -n "$BACKUP_NS" get secret platform-backup-s3 -o jsonpath='{.data.secret_access_key}' | base64 -d)"
  printf 'user = "%s:%s"\n' "$ak" "$sk" | write_secret_file "${dir}/s3.cred"
  kubectl -n storage port-forward svc/rustfs-svc "${S3_LOCAL_PORT}:9000" --address 127.0.0.1 >/dev/null 2>&1 &
  _S3_PF_PID=$!
  S3_DIR="$dir"
  wait_for 30 "S3 port-forward" s3_curl "/${BACKUP_BUCKET}?list-type=2&max-keys=1"
}
s3_session_stop() { if [[ -n "$_S3_PF_PID" ]]; then kill "$_S3_PF_PID" 2>/dev/null || true; fi; }

# s3_curl <path+query> [curl args]: signed request against platform-backup's endpoint
s3_curl() {
  local path="$1"; shift
  curl -fsS --noproxy '*' --cacert "${S3_DIR}/ca.crt" --resolve "${S3_HOST}:${S3_LOCAL_PORT}:127.0.0.1" \
    --aws-sigv4 "aws:amz:us-east-1:s3" -K "${S3_DIR}/s3.cred" "$@" "https://${S3_HOST}:${S3_LOCAL_PORT}${path}"
}

# s3_keys <prefix>: object keys below the prefix (first 1000), sorted
s3_keys() {
  s3_curl "/${BACKUP_BUCKET}?list-type=2&prefix=$1" | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g' | sort
}

# clusters_with_backup: CloudNativePG clusters in the database namespace that archive to S3
clusters_with_backup() {
  kubectl -n "$DB_NS" get clusters.postgresql.cnpg.io -o json \
    | jq -r '.items[] | select(.spec.backup.barmanObjectStore != null) | .metadata.name'
}

# pg_backup <cluster> <backup-name>: on-demand base backup, waits for completion
pg_backup() {
  local cluster="$1" name="$2" phase=""
  kubectl apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${name}
  namespace: ${DB_NS}
  labels: {boccob.io/backup: on-demand}
spec:
  cluster: {name: ${cluster}}
  method: barmanObjectStore
YAML
  local _
  for _ in $(seq 1 120); do
    phase="$(kubectl -n "$DB_NS" get backup "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == completed || "$phase" == failed ]] && break
    sleep 5
  done
  [[ "$phase" == completed ]] || { err "backup ${name}: ${phase:-timeout} $(kubectl -n "$DB_NS" get backup "$name" -o jsonpath='{.status.error}' 2>/dev/null)"; return 1; }
  log "backup ${name} of ${cluster} completed"
}

# pg_restore_cluster <source-cluster> <new-cluster> [target-time RFC3339]
# Creates a NEW CloudNativePG cluster recovered from the source cluster's
# object-store backup (base backup + WAL replay up to target time or the end).
pg_restore_cluster() {
  local src="$1" dst="$2" target="${3:-}" spec
  spec="$(kubectl -n "$DB_NS" get cluster "$src" -o json)"
  jq -n --argjson s "$spec" --arg dst "$dst" --arg ns "$DB_NS" --arg target "$target" \
       --arg size "${RESTORE_STORAGE_SIZE:-1Gi}" '{
    apiVersion: "postgresql.cnpg.io/v1", kind: "Cluster",
    metadata: {name: $dst, namespace: $ns, labels: {"boccob.io/restore-of": $s.metadata.name}},
    spec: {
      instances: 1,
      imageName: $s.spec.imageName,
      storage: ({size: $size} + (if $s.spec.storage.storageClass then {storageClass: $s.spec.storage.storageClass} else {} end)),
      resources: {requests: {cpu: "50m", memory: "192Mi"}, limits: {memory: "512Mi"}},
      enableSuperuserAccess: false,
      bootstrap: {recovery: ({source: "origin"} + (if $target != "" then {recoveryTarget: {targetTime: $target}} else {} end))},
      externalClusters: [{
        name: "origin",
        barmanObjectStore: ($s.spec.backup.barmanObjectStore
          | {destinationPath, endpointURL, endpointCA, s3Credentials, wal: {compression: .wal.compression}}
          + {serverName: $s.metadata.name})
      }]
    }}' | kubectl apply -f - >/dev/null
  log "restoring ${src} -> ${dst}${target:+ (target time ${target})}"
  kubectl -n "$DB_NS" wait --for=condition=Ready "cluster/${dst}" --timeout="${RESTORE_TIMEOUT:-900s}" >/dev/null
}

# openbao_latest_snapshot: newest snapshot key below openbao/
openbao_latest_snapshot() { s3_keys "openbao/" | grep '\.snap$' | tail -n 1; }

# openbao_snapshot_check <key> <workdir>: download + integrity checks
#   1. sha256 of the object matches the .sha256 written at backup time
#   2. archive structure (gzip tar with meta.json, state.bin, SHA256SUMS)
#   3. the SHA256SUMS inside the archive match its content
openbao_snapshot_check() {
  local key="$1" dir="$2" want got
  s3_curl "/${BACKUP_BUCKET}/${key}" -o "${dir}/snap"
  want="$(s3_curl "/${BACKUP_BUCKET}/${key}.sha256" | tr -d '[:space:]')"
  got="$(sha256_of "${dir}/snap")"
  [[ "$want" == "$got" ]] || { err "snapshot ${key}: sha256 ${got} != recorded ${want}"; return 1; }
  mkdir -p "${dir}/x"
  tar -xzf "${dir}/snap" -C "${dir}/x" || { err "snapshot ${key}: not a gzip tar archive"; return 1; }
  local f
  for f in meta.json state.bin SHA256SUMS; do
    [[ -s "${dir}/x/${f}" ]] || { err "snapshot ${key}: ${f} missing"; return 1; }
  done
  ( cd "${dir}/x" && sha256sum -c --quiet SHA256SUMS ) || { err "snapshot ${key}: internal checksums differ"; return 1; }
  jq -e '.Index > 0' "${dir}/x/meta.json" >/dev/null || { err "snapshot ${key}: meta.json without raft index"; return 1; }
  log "snapshot ${key}: $(stat -c %s "${dir}/snap") bytes, raft index $(jq -r .Index "${dir}/x/meta.json"), checksums OK"
}
