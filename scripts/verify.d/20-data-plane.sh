# shellcheck shell=bash
# Data-plane checks (stacks 20-catalog, 21-query, 22-orchestration). Sourced by
# scripts/verify.sh: uses check(), step(), $tmp, $ca. Read-only except for a
# throw-away Iceberg schema `curated.verify_smoke_<random>` that is dropped again.
# The full functional proof (Dagster runs, masking, erasure) is scripts/dev/e2e.sh.
# shellcheck disable=SC2154  # $tmp and $ca come from scripts/verify.sh
# shellcheck source=../lib/dataplane.sh
source "${REPO_ROOT}/scripts/lib/dataplane.sh"

if kubectl get namespace catalog query orchestration >/dev/null 2>&1; then
  step "data plane: Polaris"
  check "CloudNativePG clusters polaris-db and dagster-db healthy" bash -c \
    'for c in polaris-db dagster-db; do kubectl -n database get cluster "$c" -o json | jq -e ".status.readyInstances == .spec.instances" >/dev/null || exit 1; done'
  check "Polaris ready" kubectl -n catalog wait --for=condition=Available deploy/polaris --timeout=10s
  check "Polaris uses the PostgreSQL metastore (relational-jdbc)" bash -c \
    "kubectl -n catalog get configmap polaris -o jsonpath='{.data.application\.properties}' | grep -q '^polaris.persistence.type=relational-jdbc'"
  check "Polaris API serves TLS from the platform CA (ingress, OAuth2 required)" bash -c \
    "test \"\$(curl -sS -o /dev/null -w '%{http_code}' --noproxy '*' --cacert '$ca' --resolve 'polaris.${BASE_DOMAIN}:443:${DP_INGRESS_IP}' https://polaris.${BASE_DOMAIN}/api/management/v1/catalogs)\" = 401"
  check "Polaris principal credentials stored in OpenBao (synced for Trino)" bash -c \
    "kubectl -n query get secret trino-polaris -o jsonpath='{.data.credential}' | base64 -d | grep -q ':'"

  step "data plane: OPA + Trino"
  check "OPA ready with the policy bundle activated" kubectl -n query wait --for=condition=Available deploy/opa --timeout=10s
  check "OPA bundle is pinned by digest" bash -c \
    "kubectl -n query get configmap opa-config -o jsonpath='{.data.config\.yaml}' | grep -Eq '\"?resource\"?: \"?[^\" ]+@sha256:[0-9a-f]{64}'"
  check "Trino coordinator ready" kubectl -n query wait --for=condition=Available deploy/trino-coordinator --timeout=10s
  check "Trino catalogs raw/clean/consolidated/curated (svc-dagster over TLS, password auth)" bash -c \
    "$(declare -f dp_trino_sa dp_secret); REPO_ROOT='$REPO_ROOT' DP_TRINO_URL='$DP_TRINO_URL' DP_INGRESS_IP='$DP_INGRESS_IP' dp_trino_sa svc-dagster '$ca' 'show catalogs' | tr -d '\"[]' | sort | tr '\n' ' ' | grep -qx 'clean consolidated curated raw system '"
  vs_schema="verify_smoke_$(random_secret 9 | tr -dc 'a-z0-9' | head -c 8)"
  dp_iceberg_roundtrip() {
    local q=(dp_trino_sa svc-dagster "$ca")
    "${q[@]}" "create schema curated.${vs_schema}" >/dev/null &&
      "${q[@]}" "create table curated.${vs_schema}.t as select 42 as x" >/dev/null &&
      "${q[@]}" "select x from curated.${vs_schema}.t" | grep -qx '\[42\]'
    local rc=$?
    "${q[@]}" "drop table if exists curated.${vs_schema}.t" >/dev/null 2>&1
    "${q[@]}" "drop schema if exists curated.${vs_schema}" >/dev/null 2>&1
    return $rc
  }
  check "Iceberg round trip Trino -> Polaris -> RustFS (create/select/drop with purge)" dp_iceberg_roundtrip
  check "unauthenticated Trino request rejected" bash -c \
    "test \"\$(curl -sS -o /dev/null -w '%{http_code}' --noproxy '*' --cacert '$ca' --resolve 'trino.${BASE_DOMAIN}:443:${DP_INGRESS_IP}' -H 'X-Trino-User: svc-dagster' -X POST --data 'select 1' https://trino.${BASE_DOMAIN}/v1/statement)\" = 401"
  check "Trino group provider has the Keycloak groups (group sync)" bash -c \
    "kubectl -n query exec deploy/trino-coordinator -c trino-coordinator -- cat /groups/group.db | grep -q '^data-engineer:.*svc-dagster'"
  check "Trino writes query audit events to stdout" bash -c \
    "kubectl -n query logs deploy/trino-coordinator -c audit-log --tail=200 | grep -q '\"log_type\":\"trino-query-audit\"'"
  check "OPA writes decision logs to stdout" bash -c \
    "kubectl -n query logs deploy/opa --tail=500 | grep -q '\"decision_id\"'"
  opa_isolated() {
    # a pod of the query namespace that is not the Trino coordinator must not reach OPA
    kubectl -n query run verify-smoke-opa --restart=Never --quiet --rm -i --pod-running-timeout=120s \
      --image="$(image_zot_ref busybox)" \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"verify-smoke-opa","image":"'"$(image_zot_ref busybox)"'","command":["sh","-c","if nc -w 4 -z opa.query.svc.cluster.local 8181; then echo CONNECTED; else echo BLOCKED; fi"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"resources":{"limits":{"memory":"32Mi"}}}]}}' \
      2>/dev/null | grep -q '^BLOCKED'
  }
  check "NetworkPolicy: only the Trino coordinator can query OPA" opa_isolated

  step "data plane: Dagster"
  for d in dagster-dagster-webserver dagster-daemon dagster-code-dagster-user-deployments-lakehouse dagster-auth; do
    check "deployment ${d} ready" kubectl -n orchestration wait --for=condition=Available "deploy/${d}" --timeout=10s
  done
  check "code location loaded in the webserver (no load errors)" bash -c \
    "$(declare -f dp_dagster_graphql); echo '{\"query\":\"{ workspaceOrError { ... on Workspace { locationEntries { name locationOrLoadError { __typename } } } } }\"}' | dp_dagster_graphql | jq -e '[.data.workspaceOrError.locationEntries[] | select(.name == \"lakehouse\" and .locationOrLoadError.__typename == \"RepositoryLocation\")] | length == 1'"
  check "pool lakehouse_writer limited to 1" bash -c \
    "$(declare -f dp_dagster_graphql); echo '{\"query\":\"{ instance { concurrencyLimit(concurrencyKey: \\\"lakehouse_writer\\\") { slotCount } } }\"}' | dp_dagster_graphql | jq -e '.data.instance.concurrencyLimit.slotCount == 1'"
  check "pseudonym pepper present in the code location environment (value not shown)" bash -c \
    "kubectl -n orchestration get secret lakehouse-env -o jsonpath='{.data.PSEUDONYM_PEPPER}' | base64 -d | wc -c | awk '{exit !(\$1 >= 32)}'"
  # supply chain: the artefacts the cluster actually runs carry the platform signature
  dp_solution_refs() {
    kubectl -n orchestration get deploy dagster-code-dagster-user-deployments-lakehouse -o jsonpath='{.spec.template.spec.containers[0].image}'
    echo
    kubectl -n query get configmap opa-config -o jsonpath='{.data.config\.yaml}' | grep -Eo '[^" ]+@sha256:[0-9a-f]{64}' | head -1
  }
  check "solution artefacts in use (code-location image, OPA bundle) carry a valid cosign signature (OpenBao transit key)" bash -c \
    "refs=\$($(declare -f dp_solution_refs); dp_solution_refs | tr '\n' ' '); [[ \$(wc -w <<<\"\$refs\") -eq 2 ]] && '${REPO_ROOT}/scripts/supply-chain/sign.sh' '$ENV' verify \$refs"
  check "Kyverno: running solution pods pass verify-solution-image-signatures" bash -c \
    "! kubectl -n orchestration get policyreports -o json | jq -e -r '.items[] | select(.scope.kind == \"Pod\") | .scope.name as \$n | .results[]? | select(.policy == \"verify-solution-image-signatures\" and .result != \"pass\") | \$n' | grep ."
  check "Dagster UI requires a Keycloak login (oauth2-proxy redirect)" bash -c \
    "curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --noproxy '*' --cacert '$ca' --resolve 'dagster.${BASE_DOMAIN}:443:${DP_INGRESS_IP}' https://dagster.${BASE_DOMAIN}/ | grep -Eq '^(302|403) '"
fi
