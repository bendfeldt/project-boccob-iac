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
ops_backup_objects() {
  mkdir -p "${tmp}/s3"
  s3_session "${tmp}/s3"
  local pg snap age
  pg="$(s3_keys "postgres/" | grep -c '/base/.*/backup.info$' || true)"
  snap="$(openbao_latest_snapshot)"
  echo "postgres base backups: ${pg}, newest OpenBao snapshot: ${snap:-none}"
  [[ "$pg" -gt 0 && -n "$snap" ]] || return 1
  age=$(( $(date -u +%s) - $(date -u -d "$(sed -E 's#.*raft-([0-9]{8})T([0-9]{2})([0-9]{2})([0-9]{2})Z\.snap#\1 \2:\3:\4#' <<<"$snap")" +%s) ))
  echo "snapshot age ${age}s"
  (( age < ${VERIFY_SNAPSHOT_MAX_AGE:-7200} ))
}
check "backup objects in platform-backup (PostgreSQL base backups, OpenBao snapshot < 2h)" ops_backup_objects
if [[ "${VERIFY_RESTORE_TEST:-1}" == "1" ]]; then
  check "restore test (PITR into a scratch cluster + OpenBao snapshot integrity)" \
    "${REPO_ROOT}/scripts/backup/restore-test.sh" "$ENV"
fi

ops_cleanup
