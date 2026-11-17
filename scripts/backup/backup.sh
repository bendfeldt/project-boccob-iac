#!/usr/bin/env bash
# On-demand backup of everything the schedules cover.
#
#   scripts/backup/backup.sh <env> [postgres|openbao|offsite|all]   (default all)
#
# postgres: a base backup of every CloudNativePG cluster with an object store
# openbao:  a raft snapshot (Job from the CronJob openbao-snapshot)
# offsite:  a run of the off-site copy (when configured)
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=lib.sh
source "${REPO_ROOT}/scripts/backup/lib.sh"
load_env "${1:-${ENV:-}}"
what="${2:-${WHAT:-all}}"
require_cmd kubectl jq
ts="$(date -u +%Y%m%d%H%M%S)"
rc=0

run_job() { # run_job <cronjob>
  local cj="$1" job="${1}-manual-${ts}"
  kubectl -n "$BACKUP_NS" get cronjob "$cj" >/dev/null 2>&1 || { warn "cronjob ${cj} not deployed (stack 32-backup)"; return 0; }
  kubectl -n "$BACKUP_NS" create job "$job" --from="cronjob/${cj}" >/dev/null
  if kubectl -n "$BACKUP_NS" wait --for=condition=Complete "job/${job}" --timeout="${JOB_TIMEOUT:-600s}" >/dev/null 2>&1; then
    log "${cj}: $(kubectl -n "$BACKUP_NS" logs "job/${job}" --all-containers 2>/dev/null | grep -E 'uploaded|Summary' | tail -n 1)"
  else
    err "${cj}: job ${job} did not complete"; kubectl -n "$BACKUP_NS" logs "job/${job}" --all-containers 2>/dev/null | tail -n 5 >&2; return 1
  fi
}

if [[ "$what" == all || "$what" == postgres ]]; then
  step "PostgreSQL base backups"
  mapfile -t clusters < <(clusters_with_backup)
  [[ ${#clusters[@]} -gt 0 ]] || warn "no CloudNativePG cluster with an object-store backup"
  for c in "${clusters[@]}"; do pg_backup "$c" "${c}-manual-${ts}" || rc=1; done
fi
if [[ "$what" == all || "$what" == openbao ]]; then
  step "OpenBao raft snapshot"
  run_job openbao-snapshot || rc=1
fi
if [[ "$what" == all || "$what" == offsite ]]; then
  step "off-site copy"
  run_job offsite-copy || rc=1
fi
exit $rc
