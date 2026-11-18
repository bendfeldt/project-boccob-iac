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
#   6. deregistration-scope erasure: person gone, payments/cases kept anonymised
#   7. platform guarantees on the runs: only the erasure run pod gets the purge
#      Secret (audit N-3); step logs land in bucket dagster-compute-logs; dbt
#      refuses a full refresh of incremental models when LAKEHOUSE_ENV != dev
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

step "deregistration-scope erasure (retention policy path): person gone, bookings kept anonymised"
# a citizen (not the one above) with payments and cases; queued with scope=deregistration
# the way the retention policy does (pyiceberg, key over stdin)
dkey="$(one "select c.citizen_id from clean.borgerportal.citizens c join clean.borgerportal.payments p on p.citizen_id = c.citizen_id join clean.borgerportal.cases k on k.citizen_id = c.citizen_id where c.citizen_id <> '${key}' group by c.citizen_id order by c.citizen_id limit 1")"
if [[ -z "$dkey" || "$dkey" == null ]]; then
  bad "no deregistration candidate (citizen with payments and cases)"
else
  pay_ids="$(sa "select payment_id from clean.borgerportal.payments where citizen_id = '${dkey}'" | jq -r '.[0]' | sed "s/.*/'&'/" | paste -sd, -)"
  case_ids="$(sa "select case_id from clean.borgerportal.cases where citizen_id = '${dkey}'" | jq -r '.[0]' | sed "s/.*/'&'/" | paste -sd, -)"
  n_pay="$(tr ',' '\n' <<<"$pay_ids" | grep -c .)"; n_case="$(tr ',' '\n' <<<"$case_ids" | grep -c .)"
  dreason="e2e-dereg-$(date -u +%Y%m%dT%H%M%SZ)"
  printf '%s\n' "$dkey" | kubectl -n orchestration exec -i deploy/dagster-code-dagster-user-deployments-lakehouse -- \
    python -c 'import sys; from governance.erasure.queue import enqueue; k = sys.stdin.readline().strip(); print(enqueue(k, identifier_type="subject_key", requested_by="retention-policy", reason=sys.argv[1], scope="deregistration"))' \
    "$dreason" > "${tmp}/dereg.out" 2>"${tmp}/dereg.err" \
    && ok "deregistration request queued (${n_pay} payments, ${n_case} cases)" || bad "enqueue: $(tail -2 "${tmp}/dereg.err")"
  drun="$(dp_dagster_launch erasure)"
  log "run ${drun}"
  if dp_dagster_wait "$drun" 1800; then ok "erasure run ${drun} SUCCESS"; else bad "erasure run ${drun}"; fi
  expect "deregistered person gone from clean.borgerportal.citizens" 0 "$(one "select count(*) from clean.borgerportal.citizens where citizen_id = '${dkey}'")"
  expect "deregistered person gone from the keystore" 0 "$(one "select count(*) from curated.keystore.dim_citizen where business_key = '${dkey}'")"
  expect "payments kept, anonymised (no person link, no case number, _anonymised_at set)" "$n_pay" \
    "$(one "select count(*) from clean.borgerportal.payments where payment_id in (${pay_ids}) and citizen_id is null and case_id is null and _anonymised_at is not null")"
  expect "cases kept, anonymised (no person link, _anonymised_at set)" "$n_case" \
    "$(one "select count(*) from clean.borgerportal.cases where case_id in (${case_ids}) and citizen_id is null and _anonymised_at is not null")"
fi

step "platform guarantees on the runs"
# dp_run_envfrom <run id> -> Secrets the run pod gets through envFrom
dp_run_envfrom() {
  kubectl -n orchestration get job -l "dagster/run-id=${1}" -o json \
    | jq -r '[.items[0].spec.template.spec.containers[0].envFrom[]? | .secretRef.name // empty] | join(",")'
}
expect "erasure run pod gets the purge Secret" yes "$([[ ",$(dp_run_envfrom "$run")," == *,lakehouse-purge-env,* ]] && echo yes || echo no)"
other="$(dp_dagster_launch "${E2E_PLAIN_JOB:-migrate}")"
dp_dagster_wait "$other" 1800 >/dev/null 2>&1 || true
expect "a ${E2E_PLAIN_JOB:-migrate} run pod does not (envFrom: $(dp_run_envfrom "$other"))" no \
  "$([[ ",$(dp_run_envfrom "$other")," == *,lakehouse-purge-env,* ]] && echo yes || echo no)"
expect "no PURGE_S3_* in the environment shared by every run (lakehouse-env)" 0 \
  "$(kubectl -n orchestration get secret lakehouse-env -o json | jq '[.data | keys[] | select(startswith("PURGE_S3"))] | length')"
if kubectl -n orchestration get secret dagster-compute-logs-s3 >/dev/null 2>&1; then
  n_logs="$(kubectl -n orchestration exec -i deploy/dagster-daemon -c dagster -- python -c '
import boto3, os
s3 = boto3.client("s3", endpoint_url="https://rustfs-svc.storage.svc:9000", verify="/etc/platform-ca/ca.crt")
r = s3.list_objects_v2(Bucket="dagster-compute-logs", Prefix="dagster/storage/'"${run}"'")
print(r.get("KeyCount", 0))' 2>&1 | tail -1)"
  [[ "$n_logs" =~ ^[0-9]+$ ]] && (( n_logs > 0 )) && ok "step logs of the erasure run in s3://dagster-compute-logs (${n_logs} objects)" \
    || bad "no compute logs of run ${run} in dagster-compute-logs: ${n_logs}"
else
  bad "compute logs to S3 not configured (compute_logs_s3 = false)"
fi
# full-refresh guard: dbt in the code-location image with LAKEHOUSE_ENV=test and an
# unreachable Trino - the on-run-start guard must refuse before any connection
if kubectl -n orchestration exec deploy/dagster-code-dagster-user-deployments-lakehouse -- env LAKEHOUSE_ENV=test TRINO_HOST=refused.invalid \
     DBT_TARGET_PATH=/tmp/dbt-target DBT_LOG_PATH=/tmp/dbt-logs \
     sh -c 'cd "$DBT_PROJECT_DIR" && dbt run --full-refresh --select clean.borgerportal.citizens' > "${tmp}/fr.out" 2>&1; then
  bad "dbt --full-refresh ran with LAKEHOUSE_ENV=test"
else
  grep -q "refused outside dev" "${tmp}/fr.out" && ok "dbt --full-refresh refused with LAKEHOUSE_ENV=test (guard message)" \
    || bad "full refresh failed for another reason: $(grep -m2 -i error "${tmp}/fr.out")"
fi

printf '\n== e2e summary (%s): %d passed, %d failed\n' "$ENV" "$PASS" "$FAIL"
(( FAIL == 0 ))
