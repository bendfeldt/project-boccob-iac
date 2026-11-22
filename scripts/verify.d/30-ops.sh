# shellcheck shell=bash
# Ops checks (stacks 30-observability, 31-policy, 32-backup). Sourced by
# scripts/verify.sh: uses check(), step(), $tmp, $ca, s3_list, image_zot_ref.
# Every check runs inside check() so that a failure never aborts verify.sh.
# VERIFY_RESTORE_TEST=0 skips the (slow, ~1-2 min) restore test.
# shellcheck disable=SC2154  # $tmp and $ca come from scripts/verify.sh
# shellcheck source=../backup/lib.sh
source "${REPO_ROOT}/scripts/backup/lib.sh"

OPS_NS="verify-smoke-ops"
ops_marker="verify-smoke-$(random_secret 9 | tr -dc 'a-z0-9' | head -c 10)"
_OPS_PF=()
ops_pf() { # ops_pf <ns> <svc> <local>:<remote>
  kubectl -n "$1" port-forward "svc/$2" "$3" --address 127.0.0.1 >/dev/null 2>&1 &
  _OPS_PF+=($!)
  sleep 2
}
ops_cleanup() {
  local p
  for p in "${_OPS_PF[@]}"; do kill "$p" 2>/dev/null || true; done
  s3_session_stop
  kubectl delete namespace "$OPS_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

prom_q() { # prom_q <promql> -> JSON result array
  curl -fsS --noproxy '*' -G "http://127.0.0.1:19090/api/v1/query" --data-urlencode "query=$1" | jq -c '.data.result'
}
loki_q() { # loki_q <tenant> <logql> [minutes] -> number of matching lines
  local start; start="$(( $(date -u +%s) - ${3:-15} * 60 ))000000000"
  curl -fsS --noproxy '*' --cacert "$ca" --resolve "loki.observability.svc:13100:127.0.0.1" \
    -H "X-Scope-OrgID: $1" -G "https://loki.observability.svc:13100/loki/api/v1/query_range" \
    --data-urlencode "query=$2" --data-urlencode "start=${start}" --data-urlencode "limit=100" \
    | jq '[.data.result[].values[]] | length'
}

# ------------------------------------------------------------------------------
step "Observability"
if kubectl -n observability get svc prometheus-server >/dev/null 2>&1; then
  ops_pf observability prometheus-server 19090:80
  ops_pf observability loki 13100:3100
  check "Prometheus: all scrape targets up" bash -c \
    "$(declare -f prom_q); r=\$(prom_q 'count(up == 0) or vector(0)'); echo \"down: \$r\"; jq -e '.[0].value[1] == \"0\"' <<<\"\$r\" >/dev/null && [[ \$(prom_q 'count(up)' | jq -r '.[0].value[1]') -ge 10 ]]"
  check "Prometheus: OpenBao unsealed (vault_core_unsealed == 1)" bash -c \
    "$(declare -f prom_q); prom_q 'min(vault_core_unsealed)' | jq -e '.[0].value[1] == \"1\"'"
  check "Prometheus: alert rules loaded and healthy" bash -c \
    "curl -fsS --noproxy '*' http://127.0.0.1:19090/api/v1/rules | jq -e '[.data.groups[].rules[]] | length > 10 and all(.health == \"ok\")'"

  # end to end: a pod writes a marker line -> collector -> Loki (tenant platform);
  # its creation is recorded by the API audit log -> tenant audit
  ops_log_pod() {
    kubectl create namespace "$OPS_NS" >/dev/null 2>&1 || true
    # enforced namespace: the pod is only admitted if it passes every policy
    kubectl label namespace "$OPS_NS" boccob.io/policy-enforce=true --overwrite >/dev/null
    local img; img="$(image_zot_ref busybox)"
    kubectl -n "$OPS_NS" run "$ops_marker" --restart=Never --image="$img" --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"log","image":"'"$img"'","command":["sh","-c","echo '"$ops_marker"'; sleep 2"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  }
  check "Kyverno admits a compliant pod (mirror image by digest, non-root, read-only rootfs, limits)" ops_log_pod
  ops_wait_loki() { # ops_wait_loki <tenant> <logql>
    local i
    for i in $(seq 1 30); do
      [[ "$(loki_q "$1" "$2" 2>/dev/null || echo 0)" -gt 0 ]] && return 0
      sleep 4
    done
    echo "not found in tenant $1 after $((i * 4))s: $2"; return 1
  }
  check "Loki: pod log line queryable (tenant platform)" ops_wait_loki platform "{k8s_namespace_name=\"${OPS_NS}\"} |= \"${ops_marker}\""
  check "Loki: Kubernetes API audit event for that pod queryable (tenant audit)" ops_wait_loki audit "{service_name=\"kube-apiserver\"} |= \"${ops_marker}\""
  check "Loki: OpenBao audit device lines in tenant audit" ops_wait_loki audit "{k8s_namespace_name=\"secrets\"} |= \"\\\"type\\\":\\\"response\\\"\""
  check "Loki: audit lines are NOT in tenant platform (separation)" bash -c \
    "$(declare -f loki_q); ca='$ca'; [[ \$(loki_q platform '{service_name=\"kube-apiserver\"}' 60) -eq 0 ]]"
  check "audit archive bucket platform-audit has object lock" bash -c \
    "$(declare -f s3_list icurl); ca='$ca' INGRESS_PORT='$INGRESS_PORT' INGRESS_IP='$INGRESS_IP' s3_host='$s3_host' s3_list '/platform-audit?object-lock' | grep -q '<ObjectLockEnabled>Enabled</ObjectLockEnabled>'"
else
  check "observability stack deployed (30-observability)" false
fi

# ------------------------------------------------------------------------------
step "Policy (Kyverno)"
check "Kyverno controllers ready" kubectl -n kyverno wait --for=condition=Available deploy --all --timeout=30s
check "Kyverno policies ready" bash -c \
  'kubectl get validatingpolicies.policies.kyverno.io -o json | jq -e "(.items | length) >= 6 and all(.items[]; any(.status.conditionStatus.conditions[]?; .type == \"WebhookConfigured\" and .status == \"True\") or (.status.conditionStatus.ready == true))"'
check "Kyverno policy reports present" bash -c '[[ $(kubectl get policyreports.wgpolicyk8s.io -A --no-headers 2>/dev/null | wc -l) -gt 0 ]]'
ops_policy_block() {
  kubectl create namespace "$OPS_NS" >/dev/null 2>&1 || true
  kubectl label namespace "$OPS_NS" boccob.io/policy-enforce=true --overwrite >/dev/null
  local out
  out="$(kubectl -n "$OPS_NS" run bad --image=docker.io/library/nginx:latest --restart=Never --dry-run=server 2>&1 || true)"
  kubectl label namespace "$OPS_NS" boccob.io/policy-enforce- >/dev/null 2>&1 || true
  echo "$out" | tail -n 1 | cut -c1-300
  grep -q "restrict-image-registries" <<<"$out" && grep -q "disallow-latest-tag" <<<"$out" && grep -q "require-image-digest" <<<"$out"
}
check "Kyverno blocks a non-compliant pod (upstream registry, :latest, no digest) in an enforced namespace" ops_policy_block
check "Kyverno exception honoured (keycloak: no read-only-rootfs failure reported)" bash -c \
  '! kubectl -n identity get policyreports.wgpolicyk8s.io -o json | jq -e "[.items[].results[]? | select(.policy == \"require-read-only-root-filesystem\" and .result == \"fail\")] | length > 0"'

# ------------------------------------------------------------------------------
step "Secret isolation (per-namespace stores)"
# ops_es_denied <store kind> <store> <kv path> [namespace]: an ExternalSecret in
# the namespace (default observability) must NOT be able to read the path
ops_es_denied() {
  local name ns="${4:-observability}"
  name="verify-smoke-isolation-$(tr '[:upper:]' '[:lower:]' <<<"${1:0:1}")"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: ${name}, namespace: ${ns}}
spec:
  refreshInterval: 1m0s
  secretStoreRef: {name: ${2}, kind: ${1}}
  target: {name: ${name}, creationPolicy: Owner}
  dataFrom: [{extract: {key: ${3}}}]
YAML
  local i st=""
  for i in $(seq 1 15); do
    st="$(kubectl -n "$ns" get externalsecret "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ -n "$st" ]] && break
    sleep 2
  done
  echo "Ready=${st:-none}: $(kubectl -n "$ns" get externalsecret "$name" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null | cut -c1-160)"
  kubectl -n "$ns" delete externalsecret "$name" --ignore-not-found >/dev/null 2>&1
  ! kubectl -n "$ns" get secret "$name" >/dev/null 2>&1 && [[ "$st" != "True" ]]
}
check "namespaced store: observability reads a granted path (storage/s3-users/platform-logs)" bash -c \
  "$(declare -f ops_es_denied); ! ops_es_denied SecretStore openbao storage/s3-users/platform-logs"
check "namespaced store: observability cannot read orchestration/pseudonym-pepper" ops_es_denied SecretStore openbao orchestration/pseudonym-pepper
check "no cluster-wide store grants observability the pepper (legacy ClusterSecretStore absent or refusing)" ops_es_denied ClusterSecretStore openbao orchestration/pseudonym-pepper
check "namespaced store: database cannot read the lake reader credential (storage/s3-users/platform-offsite-reader)" \
  ops_es_denied SecretStore openbao storage/s3-users/platform-offsite-reader database
check "S3 user platform-backup (held by database + backup) has no grant on the lake buckets" bash -c \
  'kubectl -n storage get configmap rustfs-provision -o json | jq -e ".data[\"policy-platform-backup.json\"] | fromjson | [.Statement[].Resource[] | select(startswith(\"arn:aws:s3:::lakehouse-\"))] | length == 0"'
check "foundation namespaces use their own SecretStores only" bash -c \
  'r=$(kubectl get externalsecret,pushsecret -A -o json | jq -r ".items[] | select(.metadata.namespace | IN(\"database\",\"storage\",\"identity\",\"observability\",\"backup\")) | select((.spec.secretStoreRef.kind // .spec.secretStoreRefs[0].kind // \"none\") == \"ClusterSecretStore\") | .metadata.namespace + \"/\" + .metadata.name"); echo "${r:-none}"; [[ -z "$r" ]]'

# ------------------------------------------------------------------------------
step "Object storage lifecycle (erasure finality)"
for b in lakehouse-raw lakehouse-clean lakehouse-consolidated lakehouse-curated; do
  check "bucket ${b}: noncurrent versions + expired delete markers expire (lifecycle)" bash -c \
    "$(declare -f s3_list icurl); ca='$ca' INGRESS_PORT='$INGRESS_PORT' INGRESS_IP='$INGRESS_IP' s3_host='$s3_host' s3_list '/${b}?lifecycle' > '${tmp}/lc-${b}'; grep -q '<NoncurrentDays>' '${tmp}/lc-${b}' && grep -q '<ExpiredObjectDeleteMarker>true' '${tmp}/lc-${b}'"
done

# ------------------------------------------------------------------------------
step "Backup"
check "every CloudNativePG cluster archives WAL (ContinuousArchiving=True)" bash -c \
  'kubectl -n database get clusters.postgresql.cnpg.io -o json | jq -e "[.items[] | select(.spec.backup.barmanObjectStore != null)] as \$b | (\$b | length) > 0 and all(\$b[]; any(.status.conditions[]?; .type == \"ContinuousArchiving\" and .status == \"True\"))"'
check "CloudNativePG clusters without backup configuration (should be none)" bash -c \
  'r=$(kubectl -n database get clusters.postgresql.cnpg.io -o json | jq -r ".items[] | select(.spec.backup.barmanObjectStore == null) | .metadata.name"); echo "without backup: ${r:-none}"; [[ -z "$r" ]]'
ops_backup_objects() ( # subshell: a die() in the S3 helpers must not end verify.sh
  trap s3_session_stop EXIT
  mkdir -p "${tmp}/s3"
  s3_session "${tmp}/s3"
  local pg snap age
  pg="$(s3_keys "postgres/" | grep -c '/base/.*/backup.info$' || true)"
  snap="$(openbao_latest_snapshot)"
  echo "postgres base backups: ${pg}, newest OpenBao snapshot: ${snap:-none}"
  [[ "$pg" -gt 0 && -n "$snap" ]] || return 1
  age=$(( $(date -u +%s) - $(snapshot_epoch "$snap") ))
  echo "snapshot age ${age}s"
  (( age < ${VERIFY_SNAPSHOT_MAX_AGE:-7200} ))
)
check "backup objects in platform-backup (PostgreSQL base backups, OpenBao snapshot < 2h)" ops_backup_objects
# off-site lake copy: separate target, checked before every run (no object lock,
# short noncurrent expiry) so that erasure reaches the copy (audit N-2)
ops_offsite_lake() {
  local job
  job="verify-offsite-lake-$(date +%s)"
  kubectl -n backup create job "$job" --from=cronjob/offsite-lake-copy >/dev/null || return 1
  kubectl -n backup wait --for=condition=complete "job/${job}" --timeout=240s >/dev/null 2>&1
  local rc=$? out
  out="$(kubectl -n backup logs "job/${job}" 2>/dev/null)"
  grep -E '^(target check|REFUSED)' <<<"$out"
  kubectl -n backup delete job "$job" --ignore-not-found >/dev/null 2>&1
  [[ $rc -eq 0 ]] && grep -q '^target check ok' <<<"$out"
}
if kubectl -n backup get cronjob offsite-lake-copy >/dev/null 2>&1; then
  check "off-site lake copy: target bucket passes the erasure check (no object lock, noncurrent expiry) and mirrors" ops_offsite_lake
  check "off-site lake copy reads with platform-offsite-reader, backups copy with platform-backup" bash -c \
    'kubectl -n backup get cronjob offsite-lake-copy -o json | jq -e "[.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == \"SRC_ACCESS_KEY\") | .valueFrom.secretKeyRef.name] == [\"platform-offsite-reader-s3\"]" && kubectl -n backup get configmap offsite-copy -o jsonpath="{.data.mirror\.sh}" | grep -c "rc mirror" | grep -qx 1'
fi
if [[ "${VERIFY_RESTORE_TEST:-1}" == "1" ]]; then
  check "restore test (PITR into a scratch cluster + OpenBao snapshot integrity)" \
    "${REPO_ROOT}/scripts/backup/restore-test.sh" "$ENV"
fi

ops_cleanup
