#!/usr/bin/env bash
# Smoke test of the cluster and the foundation layer. Exit code != 0 when any
# check fails. Creates only short-lived objects prefixed "verify-smoke".
#
#   scripts/verify.sh <env>
#
# Needs an OpenBao token for two checks (audit devices, ESO round trip):
# dev uses the root token from the init file, other environments BAO_TOKEN.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/openbao.sh
source "${REPO_ROOT}/scripts/lib/openbao.sh"
# shellcheck source=lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
load_env "${1:-${ENV:-}}"
require_cmd kubectl jq curl openssl

PASS=0; FAIL=0; RESULTS=()
tmp="$(mktemp -d)"
cleanup() {
  openbao_port_forward_stop
  kubectl -n database delete externalsecret verify-smoke --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n database delete secret verify-smoke --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n platform-system delete certificate verify-smoke --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n platform-system delete secret verify-smoke-tls --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace verify-smoke --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# check <description> <command...> : command output is kept for the report on failure
check() {
  local desc="$1"; shift
  if "$@" >"${tmp}/out" 2>&1; then
    PASS=$((PASS + 1)); RESULTS+=("PASS  ${desc}")
    printf '  [PASS] %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); RESULTS+=("FAIL  ${desc}")
    printf '  [FAIL] %s\n' "$desc"
    sed 's/^/         /' "${tmp}/out" | tail -n 8
  fi
}

ca="${tmp}/platform-ca.crt"
kubectl -n platform-system get configmap platform-ca -o jsonpath='{.data.ca\.crt}' > "$ca" 2>/dev/null || true
# ingress is reached on the node address (dev: loopback ports of the node container)
INGRESS_IP="${INGRESS_IP:-127.0.0.1}"
INGRESS_PORT="${INGRESS_PORT:-${DEV_HTTPS_PORT:-443}}"
icurl() { # icurl <host> <path> [curl args]
  local host="$1" path="$2"; shift 2
  curl -fsS --noproxy '*' --cacert "$ca" --resolve "${host}:${INGRESS_PORT}:${INGRESS_IP}" "$@" "https://${host}:${INGRESS_PORT}${path}"
}

# ------------------------------------------------------------------------------
step "cluster"
check "kube-apiserver ready" kubectl get --raw /readyz
check "all nodes Ready" bash -c '! kubectl get nodes --no-headers | grep -v " Ready "'
check "no pod in a failed/pending state" bash -c \
  '! kubectl get pods -A --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded | grep .'
check "all containers of running pods are ready" bash -c \
  '! kubectl get pods -A --field-selector=status.phase=Running -o json | jq -e -r ".items[] | select(any(.status.containerStatuses[]?; .ready == false)) | .metadata.namespace + \"/\" + .metadata.name" | grep .'
if [[ "$CLUSTER_MODE" == "podman" ]]; then
  node="${CLUSTER_NAME}-server-0"
  check "k3s secrets encryption at rest enabled" bash -c "podman exec '$node' k3s secrets-encrypt status | grep -q 'Encryption Status: Enabled'"
  check "kube-apiserver audit log is written" podman exec "$node" test -s /var/log/kubernetes/audit/audit.log
  check "node cannot fall back to upstream registries" bash -c "podman exec '$node' grep -q 'disable-default-registry-endpoint: true' /etc/rancher/k3s/config.yaml"
fi
check "Pod Security: privileged pod rejected in a restricted namespace" bash -c \
  '! kubectl -n identity run verify-smoke-priv --image=x --restart=Never --privileged --dry-run=server 2>&1 | grep -q created'
check "workload images come only from the Zot mirror" bash -c \
  "! kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.namespace != \"kube-system\") | .spec.containers[].image, (.spec.initContainers // [])[].image' | sort -u | grep -v '^${REGISTRY_HOST}/'"
check "workload images are pinned by digest" bash -c \
  "! kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.namespace != \"kube-system\") | .spec.containers[].image' | sort -u | grep -v '@sha256:'"
check "registry holds every locked image and chart" "${REPO_ROOT}/scripts/airgap/mirror.sh" check "$ENV"
check "tofu state is encrypted (no plaintext in the state Secret)" bash -c \
  'kubectl -n tofu-state get secret tfstate-default-12-foundation-services -o jsonpath="{.data.tfstate}" | base64 -d | gunzip | jq -e "has(\"encrypted_data\") and (has(\"resources\") | not)"'

# ------------------------------------------------------------------------------
step "OpenBao"
replicas="$(kubectl -n secrets get statefulset openbao -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
check "OpenBao pods ready (${replicas})" kubectl -n secrets wait --for=condition=Ready pod -l app.kubernetes.io/name=openbao,component=server --timeout=10s
have_token=0
if (openbao_port_forward_start) >/dev/null 2>&1; then
  openbao_port_forward_start
  bao_api() { curl -fsS --noproxy '*' --cacert "$VAULT_CACERT" --resolve "openbao.secrets.svc:${VAULT_ADDR##*:}:127.0.0.1" -H "X-Vault-Token: ${VAULT_TOKEN:-}" "$@"; }
  bao_url="https://openbao.secrets.svc:${VAULT_ADDR##*:}/v1"
  check "OpenBao initialised and unsealed" bash -c "$(declare -f bao_api); VAULT_CACERT='$VAULT_CACERT' VAULT_ADDR='$VAULT_ADDR' bao_api '${bao_url}/sys/seal-status' | jq -e '.initialized == true and .sealed == false'"
  if (openbao_export_token) >/dev/null 2>&1; then
    openbao_export_token; have_token=1
    export VAULT_TOKEN VAULT_CACERT VAULT_ADDR
    check "OpenBao audit devices enabled (stdout + file)" bash -c "$(declare -f bao_api); bao_api '${bao_url}/sys/audit' | jq -e '(.data // .) | has(\"stdout/\") and has(\"file/\")'"
    check "OpenBao mounts: kv (v2), pki, pki_int" bash -c "$(declare -f bao_api); bao_api '${bao_url}/sys/mounts' | jq -e '(.data // .) | (.[\"kv/\"].options.version == \"2\") and has(\"pki/\") and has(\"pki_int/\")'"
    check "OpenBao kubernetes auth enabled" bash -c "$(declare -f bao_api); bao_api '${bao_url}/sys/auth' | jq -e '(.data // .) | has(\"kubernetes/\")'"
    check "OpenBao raft peers = ${replicas}" bash -c "$(declare -f bao_api); bao_api '${bao_url}/sys/storage/raft/configuration' | jq -e '.data.config.servers | length == ${replicas}'"
  else
    warn "no OpenBao token available (set BAO_TOKEN): skipping authenticated OpenBao checks"
  fi
else
  check "OpenBao reachable and unsealed" false
fi

# ------------------------------------------------------------------------------
step "PKI / cert-manager"
check "ClusterIssuer openbao-pki Ready" kubectl wait --for=condition=Ready clusterissuer/openbao-pki --timeout=10s
issue_cert() {
  kubectl apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: verify-smoke
  namespace: platform-system
spec:
  secretName: verify-smoke-tls
  commonName: verify-smoke.platform-system.svc
  dnsNames: ["verify-smoke.platform-system.svc", "verify-smoke.${BASE_DOMAIN}"]
  duration: 1h
  renewBefore: 30m
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {group: cert-manager.io, kind: ClusterIssuer, name: openbao-pki}
YAML
  kubectl -n platform-system wait --for=condition=Ready certificate/verify-smoke --timeout=90s >/dev/null
  kubectl -n platform-system get secret verify-smoke-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "${tmp}/smoke.crt"
  # leaf + chain must verify against the platform CA bundle, and come from the issuing CA
  openssl verify -CAfile "$ca" -untrusted "${tmp}/smoke.crt" "${tmp}/smoke.crt"
  openssl x509 -in "${tmp}/smoke.crt" -noout -issuer | grep -q 'Issuing CA'
}
check "certificate issued by the OpenBao PKI and chains to the platform CA" issue_cert

# ------------------------------------------------------------------------------
step "External Secrets"
check "ClusterSecretStores Ready" bash -c 'kubectl wait --for=condition=Ready clustersecretstore/openbao clustersecretstore/openbao-push --timeout=10s'
check "all ExternalSecrets synced" bash -c \
  '! kubectl get externalsecret -A -o json | jq -e -r ".items[] | select(any(.status.conditions[]?; .type == \"Ready\" and .status != \"True\")) | .metadata.namespace + \"/\" + .metadata.name" | grep .'
check "all PushSecrets synced" bash -c \
  '! kubectl get pushsecret -A -o json | jq -e -r ".items[] | select(any(.status.conditions[]?; .type == \"Ready\" and .status != \"True\")) | .metadata.namespace + \"/\" + .metadata.name" | grep .'
eso_roundtrip() {
  local value; value="smoke-$(random_secret 12)"
  jq -n --arg v "$value" '{data: {value: $v}}' | bao_api -X POST --data-binary @- "${bao_url}/kv/data/platform/verify-smoke" >/dev/null
  kubectl apply -f - >/dev/null <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: verify-smoke
  namespace: database
spec:
  refreshInterval: 1m0s
  secretStoreRef: {name: openbao, kind: ClusterSecretStore}
  target: {name: verify-smoke}
  dataFrom:
    - extract: {key: platform/verify-smoke}
YAML
  kubectl -n database wait --for=condition=Ready externalsecret/verify-smoke --timeout=60s >/dev/null
  local got; got="$(kubectl -n database get secret verify-smoke -o jsonpath='{.data.value}' | base64 -d)"
  bao_api -X DELETE "${bao_url}/kv/metadata/platform/verify-smoke" >/dev/null
  [[ "$got" == "$value" ]]
}
if [[ "$have_token" == "1" ]]; then
  check "ESO syncs a secret written to OpenBao KV into a Kubernetes Secret" eso_roundtrip
fi

# ------------------------------------------------------------------------------
step "PostgreSQL"
check "CloudNativePG cluster keycloak-db healthy" bash -c \
  'kubectl -n database get cluster keycloak-db -o json | jq -e ".status.readyInstances == .spec.instances and (.status.phase | test(\"healthy\"))"'
check "PostgreSQL accepts connections (database keycloak)" bash -c \
  'kubectl -n database exec keycloak-db-1 -c postgres -- psql -U postgres -d keycloak -tAc "select 1" | grep -qx 1'
pg_tls() {
  kubectl -n database port-forward svc/keycloak-db-rw 15432:5432 --address 127.0.0.1 >/dev/null 2>&1 &
  local pid=$! rc=0
  sleep 3
  echo | openssl s_client -connect 127.0.0.1:15432 -starttls postgres -CAfile "$ca" \
    -verify_hostname keycloak-db-rw.database.svc -verify_return_error 2>&1 | grep -q 'Verification: OK' || rc=1
  kill "$pid" 2>/dev/null || true
  return $rc
}
check "PostgreSQL serves TLS with a certificate from the platform CA" pg_tls

# ------------------------------------------------------------------------------
step "RustFS"
s3_host="s3.${BASE_DOMAIN}"
s3_list() {
  local ak sk
  ak="$(kubectl -n storage get secret rustfs-root -o jsonpath='{.data.RUSTFS_ACCESS_KEY}' | base64 -d)"
  sk="$(kubectl -n storage get secret rustfs-root -o jsonpath='{.data.RUSTFS_SECRET_KEY}' | base64 -d)"
  # credentials go through a curl config on stdin, not argv
  printf 'user = "%s:%s"\n' "$ak" "$sk" | icurl "$s3_host" "$1" --aws-sigv4 "aws:amz:us-east-1:s3" -K -
}
check "RustFS health endpoint over TLS (ingress, platform CA)" icurl "$s3_host" /health
s3_list / > "${tmp}/buckets.xml" 2>"${tmp}/buckets.err" || true
for b in lakehouse-raw lakehouse-clean lakehouse-consolidated lakehouse-curated platform-backup platform-logs; do
  check "bucket ${b} exists (S3 ListBuckets)" grep -q "<Name>${b}</Name>" "${tmp}/buckets.xml"
done
check "bucket versioning enabled on lakehouse-raw (S3 GetBucketVersioning)" bash -c \
  "$(declare -f s3_list icurl); ca='$ca' INGRESS_PORT='$INGRESS_PORT' INGRESS_IP='$INGRESS_IP' s3_host='$s3_host' s3_list '/lakehouse-raw?versioning' | grep -q '<Status>Enabled</Status>'"
check "S3 rejects unauthenticated requests" bash -c \
  "! curl -fsS --noproxy '*' --cacert '$ca' --resolve '${s3_host}:${INGRESS_PORT}:${INGRESS_IP}' 'https://${s3_host}:${INGRESS_PORT}/lakehouse-raw' >/dev/null 2>&1"

# ------------------------------------------------------------------------------
step "Keycloak"
kc_host="keycloak.${BASE_DOMAIN}"
check "realm lakehouse discovery over TLS, issuer matches" bash -c \
  "$(declare -f icurl); ca='$ca' INGRESS_PORT='$INGRESS_PORT' INGRESS_IP='$INGRESS_IP' icurl '$kc_host' /realms/lakehouse/.well-known/openid-configuration | jq -e '.issuer == \"https://${kc_host}/realms/lakehouse\"'"
kc_token() {
  # client-credentials grant with the polaris client secret generated in-cluster
  local secret
  secret="$(kubectl -n identity get secret oidc-client-polaris -o jsonpath='{.data.client-secret}' | base64 -d)"
  printf 'data = "grant_type=client_credentials&client_id=polaris&client_secret=%s"\n' "$secret" \
    | icurl "$kc_host" /realms/lakehouse/protocol/openid-connect/token -K - | jq -e '.access_token | length > 100' >/dev/null
}
check "OIDC client 'polaris' obtains a token with its generated secret" kc_token
kc_oidc_secret_in_bao() {
  local a b
  a="$(bao_api "${bao_url}/kv/data/identity/oidc-clients/trino" | jq -j '.data.data["client-secret"]' | sha256sum)"
  b="$(kubectl -n identity get secret oidc-client-trino -o jsonpath='{.data.client-secret}' | base64 -d | sha256sum)"
  [[ "$a" == "$b" ]]
}
if [[ "$have_token" == "1" ]]; then
  check "OIDC client secret stored in OpenBao KV (identity/oidc-clients/trino)" kc_oidc_secret_in_bao
fi

# ------------------------------------------------------------------------------
step "NetworkPolicy enforcement"
netpol_denied() {
  kubectl create namespace verify-smoke >/dev/null 2>&1 || true
  # a pod in a namespace that is NOT an allowed PostgreSQL client must be blocked;
  # the same pod must still reach DNS (proves the block is the policy, not the pod)
  kubectl -n verify-smoke run verify-smoke --restart=Never --quiet --rm -i --pod-running-timeout=120s \
    --image="$(image_zot_ref busybox)" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"verify-smoke","image":"'"$(image_zot_ref busybox)"'","command":["sh","-c","nslookup keycloak-db-rw.database.svc.cluster.local >/dev/null || { echo DNS-FAILED; exit 0; }; if nc -w 4 -z keycloak-db-rw.database.svc.cluster.local 5432; then echo CONNECTED; else echo BLOCKED; fi"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    2>/dev/null | tee "${tmp}/netpol.out"
  grep -q '^BLOCKED' "${tmp}/netpol.out"
}
check "default-deny: foreign namespace cannot reach PostgreSQL" netpol_denied

# ------------------------------------------------------------------------------
printf '\n== verify summary (%s): %d passed, %d failed\n' "$ENV" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '%s\n' "${RESULTS[@]}" | grep '^FAIL' || true
  exit 1
fi
