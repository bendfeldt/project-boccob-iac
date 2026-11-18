#!/usr/bin/env bash
# End-to-end proof of the data plane on a running environment (dev):
#   1. test users in Keycloak (scripts/dev/test-users.sh)
#   2. Dagster job daily_refresh for two partitions (initial + changed load), run
#      in the cluster by the K8sRunLauncher (dlt landing + raw index + dbt build)
#   3. via Trino over TLS with authentication: curated tables + keystore populated,
#      keys reused by the second load
#   4. access control: analyst sees masked PII and is denied raw, pii-reader sees
#      clear values (OAuth2 bearer tokens from Keycloak, groups via the group sync)
#   5. right to erasure: request queued with the solution CLI in the code-location
#      pod, Dagster job `erasure`, subject gone from clean/curated/keystore, audit row
#
#   scripts/dev/e2e.sh dev                 everything
#   E2E_SKIP_LOADS=1 scripts/dev/e2e.sh dev   reuse loads that already ran
# ok/bad always succeed, so "cond && ok || bad" is safe in this file
# shellcheck disable=SC2015
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
# shellcheck source=../lib/dataplane.sh
source "${REPO_ROOT}/scripts/lib/dataplane.sh"
require_cmd kubectl jq curl python3
[[ "$ENV" == "dev" || "${ALLOW_E2E:-0}" == "1" ]] || die "e2e writes test data: dev only (ALLOW_E2E=1 to override)"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ca="${tmp}/ca.crt"; dp_ca_file "$ca"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$*"; }
expect() { # expect <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1 (${3})"; else bad "$1: expected ${2}, got ${3}"; fi
}
sa()  { dp_trino_sa svc-dagster "$ca" "$@"; }
one() { sa "$@" | head -1 | jq -r '.[0]'; }

step "test users"
"${REPO_ROOT}/scripts/dev/test-users.sh" "$ENV" >/dev/null
sleep 40 # group sync interval (30 s) + Trino group file refresh (10 s)

if [[ "${E2E_SKIP_LOADS:-0}" != "1" ]]; then
  for partition in 2026-11-01 2026-11-02; do
    step "Dagster: daily_refresh ${partition}"
    run="$(dp_dagster_launch daily_refresh "$partition")"
    log "run ${run}"
    if dp_dagster_wait "$run" 1800; then ok "daily_refresh ${partition} run ${run} SUCCESS"; else bad "daily_refresh ${partition} run ${run}"; fi
    [[ "$partition" == 2026-11-01 ]] && keys_after_first="$(one "select max(surrogate_key) from curated.keystore.dim_citizen")"
  done
fi

step "lakehouse content (Trino over TLS, service account svc-dagster)"
for t in raw.borgerportal.citizens clean.borgerportal.citizens consolidated.party.person \
         curated.borgerservice.dim_citizen curated.borgerservice.fact_payment curated.keystore.dim_citizen; do
  n="$(one "select count(*) from ${t}")"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then ok "${t} populated (${n} rows)"; else bad "${t}: ${n}"; fi
done
expect "raw index holds at least two loads" true "$(one "select count(distinct _load_id) >= 2 from raw.borgerportal.citizens")"
dense="$(one "select count(*) = max(surrogate_key) from curated.keystore.dim_citizen where surrogate_key > 0")"
expect "keystore keys dense and sequential" true "$dense"
expect "keystore records key creation and last use" true \
  "$(one "select count(*) > 0 and count(key_last_used_in_fact_at) > 0 and count(key_created_at) = count(*) from curated.keystore.dim_citizen where surrogate_key > 0")"
expect "dimension is SCD2 (several versions for some persons)" true \
  "$(one "select count(*) > count(distinct person_id) from curated.borgerservice.dim_citizen")"
if [[ -n "${keys_after_first:-}" ]]; then
  expect "second load reused keys (keys of load 1 still present)" "$keys_after_first" \
    "$(one "select count(*) from curated.keystore.dim_citizen where surrogate_key between 1 and ${keys_after_first}")"
fi
expect "facts never fall back to the unknown member" 0 "$(one "select count(*) from curated.borgerservice.fact_payment where citizen_key < 0")"

step "access control (OPA) for Keycloak users (OAuth2 bearer tokens)"
anna="$(dp_keycloak_token anna-analyst "${STATE_DIR}/test-users/anna-analyst" "$ca")"
petra="$(dp_keycloak_token petra-pii "${STATE_DIR}/test-users/petra-pii" "$ca")"
expect "analyst sees catalogs curated + system only" '["curated"] ["system"]' \
  "$(dp_trino_user anna-analyst "$anna" "$ca" "show catalogs" | tr '\n' ' ' | sed 's/ $//')"
if dp_trino_user anna-analyst "$anna" "$ca" "select payload from raw.borgerportal.citizens limit 1" > "${tmp}/raw.out" 2>&1; then
  bad "analyst could read raw"
else
  grep -q "Access Denied" "${tmp}/raw.out" && ok "analyst denied on raw ($(head -c 80 "${tmp}/raw.out"))" || bad "analyst raw: $(cat "${tmp}/raw.out")"
fi
q="select full_name, email from curated.borgerservice.dim_citizen where citizen_key > 0 and full_name is not null order by citizen_key limit 1"
masked="$(dp_trino_user anna-analyst "$anna" "$ca" "$q")"
clear="$(dp_trino_user petra-pii "$petra" "$ca" "$q")"
[[ "$(jq -r '.[0]' <<<"$masked")" == "*****" && "$(jq -r '.[1]' <<<"$masked")" == \*\*\*\*\*@* ]] \
  && ok "analyst sees PII masked (full_name=*****, email=*****@...)" || bad "analyst PII not masked: ${masked}"
[[ "$(jq -r '.[0]' <<<"$clear")" != "*****" && "$(jq -r '.[1]' <<<"$clear")" != \*\*\*\*\** ]] \
  && ok "pii-reader sees clear values (same row, not masked)" || bad "pii-reader got masked values"
expect "analyst cannot see the keystore schema" 0 \
  "$(dp_trino_user anna-analyst "$anna" "$ca" "select count(*) from curated.information_schema.schemata where schema_name = 'keystore'" | jq -r '.[0]')"

step "right to erasure (Dagster job erasure)"
# a citizen with history and payments; only the pseudonymised id is kept in this script
subject_sql="select c.citizen_id from clean.borgerportal.citizens c join clean.borgerportal.payments p on p.citizen_id = c.citizen_id group by c.citizen_id having count(distinct c.source_updated_at) > 1 order by c.citizen_id limit 1"
key="$(one "$subject_sql")"
[[ -n "$key" && "$key" != null ]] || die "no erasure candidate"
before="$(one "select count(*) from curated.keystore.dim_citizen where business_key = '${key}'")"
log "subject: pseudonymised key ${key:0:8}..., ${before} keystore member(s)"
reason="e2e-$(date -u +%Y%m%dT%H%M%SZ)"
# the request names the subject by its pseudonymised key (the clean layer keeps no
# clear CPR any more); the key goes over stdin, never on a command line
printf '%s\n' "$key" | kubectl -n orchestration exec -i deploy/dagster-code-dagster-user-deployments-lakehouse -- \
  python -c 'import sys; from governance.erasure.cli import main; k = sys.stdin.readline().strip(); sys.exit(main(["--submit", "--subject-key", k] + sys.argv[1:]))' \
  --requested-by "dpo@kommune.example" --reason "$reason" > "${tmp}/submit.json" 2>"${tmp}/submit.err" \
  && ok "erasure request queued ($(jq -r .request_id "${tmp}/submit.json"))" || bad "submit: $(tail -2 "${tmp}/submit.err")"
run="$(dp_dagster_launch erasure)"
log "run ${run}"
if dp_dagster_wait "$run" 1800; then ok "erasure run ${run} SUCCESS"; else bad "erasure run ${run}"; fi
for check in "clean.borgerportal.citizens|citizen_id" "consolidated.party.person|person_id" \
             "curated.borgerservice.dim_citizen|person_id" "curated.keystore.dim_citizen|business_key"; do
  expect "subject gone from ${check%%|*}" 0 "$(one "select count(*) from ${check%%|*} where ${check##*|} = '${key}'")"
done
expect "audit record of the erasure (completed, no identifier)" completed \
  "$(one "select status from curated.audit.erasure_log where reason like '%${reason}%'")"
# audit H-1: neither the solution's erasure SQL nor anything else put the key into the query audit trail
if kubectl -n query logs deploy/trino-coordinator -c audit-log --since=1h | grep -qF "$key"; then
  bad "subject key found in the Trino query audit trail"
else
  ok "subject key absent from the Trino query audit trail (last hour)"
fi
expect "erasure queue empty (raw.governance.erasure_requests, written via pyiceberg)" 0 "$(one "select count(*) from raw.governance.erasure_requests")"

printf '\n== e2e summary (%s): %d passed, %d failed\n' "$ENV" "$PASS" "$FAIL"
(( FAIL == 0 ))
