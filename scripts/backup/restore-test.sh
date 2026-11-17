#!/usr/bin/env bash
# Restore TEST: proves that the backups can be restored, and measures how long
# it takes (compare with rpo_minutes / rto_minutes of stack 32-backup).
#
#   scripts/backup/restore-test.sh <env> [cluster]     default cluster: keycloak-db
#
# 1. PostgreSQL: new base backup of <cluster> + a marker row written AFTER it,
#    WAL switch; recovery into a scratch cluster restore-test-<ts> (base backup +
#    WAL replay); the restored database must contain the source's tables and the
#    marker row (= point-in-time recovery up to the archived WAL). Scratch
#    cluster deleted afterwards (KEEP=1 keeps it).
# 2. OpenBao: newest raft snapshot downloaded from S3 and checked (recorded
#    sha256, archive structure, internal SHA256SUMS, raft index). A full restore
#    into a scratch OpenBao is not automated (needs the unseal keys): runbook.
# Exit code != 0 on any failure. Result line: "restore-test PASSED|FAILED".
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=lib.sh
source "${REPO_ROOT}/scripts/backup/lib.sh"
load_env "${1:-${ENV:-}}"
cluster="${2:-${CLUSTER:-keycloak-db}}"
require_cmd kubectl jq curl tar sha256sum
ts="$(date -u +%Y%m%d%H%M%S)"
scratch="restore-test-${ts}"
tmp="$(mktemp -d)"
# shellcheck disable=SC2317  # invoked through the EXIT trap
cleanup() {
  s3_session_stop
  if [[ "${KEEP:-0}" != "1" ]]; then
    kubectl -n "$DB_NS" delete cluster "$scratch" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl -n "$DB_NS" delete backup "${cluster}-restore-test-${ts}" --ignore-not-found >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
rc=0

psql_in() { # psql_in <pod> <db> <sql>
  kubectl -n "$DB_NS" exec "$1" -c postgres -- psql -U postgres -d "$2" -v ON_ERROR_STOP=1 -tAc "$3"
}

step "PostgreSQL: ${cluster}"
primary="$(kubectl -n "$DB_NS" get cluster "$cluster" -o jsonpath='{.status.currentPrimary}')"
db="$(kubectl -n "$DB_NS" get cluster "$cluster" -o jsonpath='{.spec.bootstrap.initdb.database}')"
[[ -n "$primary" && -n "$db" ]] || die "cluster ${cluster} not found in ${DB_NS}"
pg_test() {
  pg_backup "$cluster" "${cluster}-restore-test-${ts}" || return 1
  # marker written after the base backup: only WAL replay can bring it back
  psql_in "$primary" "$db" "create schema if not exists boccob_restore_test; create table if not exists boccob_restore_test.marker(id text primary key, at timestamptz default now()); insert into boccob_restore_test.marker(id) values ('${ts}');" >/dev/null
  psql_in "$primary" "$db" "select pg_switch_wal();" >/dev/null
  local src_tables
  src_tables="$(psql_in "$primary" "$db" "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")"
  sleep "${WAL_ARCHIVE_WAIT:-20}"  # let the archiver ship the switched segment
  local start; start="$(date +%s)"
  pg_restore_cluster "$cluster" "$scratch" || { err "restore did not become Ready"; return 1; }
  local took=$(( $(date +%s) - start ))
  local pod; pod="$(kubectl -n "$DB_NS" get cluster "$scratch" -o jsonpath='{.status.currentPrimary}')"
  local got_tables marker
  got_tables="$(psql_in "$pod" "$db" "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")"
  marker="$(psql_in "$pod" "$db" "select count(*) from boccob_restore_test.marker where id = '${ts}'")"
  log "restored ${cluster} -> ${scratch} in ${took}s: tables ${got_tables}/${src_tables}, marker row ${marker}"
  [[ "$got_tables" == "$src_tables" && "$marker" == "1" ]] || { err "restored content differs from the source"; return 1; }
  psql_in "$primary" "$db" "delete from boccob_restore_test.marker where id = '${ts}'" >/dev/null || true
  echo "$took" > "${tmp}/pg_seconds"
}
if pg_test; then log "PostgreSQL restore: OK"; else err "PostgreSQL restore: FAILED"; rc=1; fi

step "OpenBao snapshot"
ob_test() {
  s3_session "$tmp"
  local key; key="$(openbao_latest_snapshot)"
  [[ -n "$key" ]] || { err "no snapshot in s3://${BACKUP_BUCKET}/openbao/"; return 1; }
  local age=$(( $(date -u +%s) - $(date -u -d "$(sed -E 's#.*raft-([0-9]{8})T([0-9]{2})([0-9]{2})([0-9]{2})Z\.snap#\1 \2:\3:\4#' <<<"$key")" +%s) ))
  log "newest snapshot ${key} is $(( age / 60 )) min old"
  openbao_snapshot_check "$key" "$tmp"
}
if ob_test; then log "OpenBao snapshot check: OK"; else err "OpenBao snapshot check: FAILED"; rc=1; fi

if [[ $rc -eq 0 ]]; then
  log "restore-test PASSED (PostgreSQL restore $(cat "${tmp}/pg_seconds" 2>/dev/null || echo '?')s)"
else
  err "restore-test FAILED"
fi
exit $rc
