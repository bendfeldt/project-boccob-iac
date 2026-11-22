#!/usr/bin/env bash
# Restore from the backups in platform-backup.
#
#   scripts/backup/restore.sh <env> postgres <cluster> <new-cluster> [<target-time RFC3339>]
#       Point-in-time recovery into a NEW CloudNativePG cluster (the source keeps
#       running). Cut-over (point the application to <new-cluster>-rw, or rename)
#       is a deliberate, separate step: docs/compliance/runbooks/disaster-recovery.md.
#   CONFIRM=<env> scripts/backup/restore.sh <env> openbao [<snapshot key>]
#       Restores an OpenBao raft snapshot (default: the newest) into the running
#       OpenBao cluster. Needs BAO_TOKEN with sudo on sys/storage/raft/snapshot
#       (dev: root token). Everything written after the snapshot is lost; OpenBao
#       must be unsealed again with the keys that were valid when it was taken.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/openbao.sh
source "${REPO_ROOT}/scripts/lib/openbao.sh"
# shellcheck source=lib.sh
source "${REPO_ROOT}/scripts/backup/lib.sh"
load_env "${1:-${ENV:-}}"
what="${2:-}"
require_cmd kubectl jq curl tar
tmp="$(mktemp -d)"
trap 's3_session_stop; openbao_port_forward_stop; rm -rf "$tmp"' EXIT

case "$what" in
  postgres)
    src="${3:?source cluster required}"; dst="${4:?new cluster name required}"; target="${5:-}"
    kubectl -n "$DB_NS" get cluster "$dst" >/dev/null 2>&1 && die "cluster ${dst} exists already"
    start="$(date +%s)"
    pg_restore_cluster "$src" "$dst" "$target"
    log "restored ${src} -> ${dst} in $(( $(date +%s) - start ))s; service ${dst}-rw.${DB_NS}.svc (credentials: Secret ${dst}-app)"
    ;;
  openbao)
    [[ "${CONFIRM:-}" == "$ENV" ]] || die "restoring OpenBao overwrites its data: set CONFIRM=${ENV}"
    s3_session "$tmp"
    key="${3:-$(openbao_latest_snapshot)}"
    [[ -n "$key" ]] || die "no snapshot found in s3://${BACKUP_BUCKET}/openbao/"
    openbao_snapshot_check "$key" "$tmp"
    openbao_port_forward_start
    openbao_export_token
    log "restoring ${key}"
    curl -fsS --noproxy '*' --cacert "$VAULT_CACERT" --resolve "openbao.secrets.svc:${VAULT_ADDR##*:}:127.0.0.1" \
      -H @<(printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN") -X POST --data-binary @"${tmp}/snap" \
      "https://openbao.secrets.svc:${VAULT_ADDR##*:}/v1/sys/storage/raft/snapshot"
    log "snapshot restored; check \`make openbao-unseal ENV=${ENV}\` and \`make verify ENV=${ENV}\`"
    ;;
  *) die "usage: restore.sh <env> postgres <cluster> <new-cluster> [time] | openbao [key]" ;;
esac
