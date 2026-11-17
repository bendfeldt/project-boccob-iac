# shellcheck shell=bash
# Helpers for scripts that talk to the data plane (verify, dev e2e).
# Requires scripts/lib/common.sh and load_env.

# ingress address as seen from this machine (dev: loopback of the node container)
DP_INGRESS_IP="${INGRESS_IP:-127.0.0.1}"
DP_TRINO_URL="https://trino.${BASE_DOMAIN}"
DP_KEYCLOAK_URL="https://keycloak.${BASE_DOMAIN}"

# dp_ca_file <path> : platform CA bundle from the cluster
dp_ca_file() {
  kubectl -n platform-system get configmap platform-ca -o jsonpath='{.data.ca\.crt}' > "$1"
}

# dp_secret <namespace> <secret> <key>
dp_secret() {
  kubectl -n "$1" get secret "$2" -o jsonpath="{.data.${3//./\\.}}" | base64 -d
}

# dp_trino_sa <user> <ca> <sql...> : query as a password-authenticated service account
dp_trino_sa() {
  local user="$1" ca="$2"; shift 2
  local pw; pw="$(dp_secret query "trino-sa-${user}" password)"
  TRINO_URL="$DP_TRINO_URL" TRINO_CA="$ca" TRINO_USER="$user" TRINO_PASSWORD="$pw" TRINO_RESOLVE="$DP_INGRESS_IP" \
    python3 -I "${REPO_ROOT}/scripts/lib/trino_query.py" "$*"
}

# dp_keycloak_token <user> <password-file> <ca> : access token (password grant on the
# trino client; dev only: direct access grants are enabled for it in the dev tfvars)
dp_keycloak_token() {
  local user="$1" pwfile="$2" ca="$3" secret
  secret="$(dp_secret identity oidc-client-trino client-secret)"
  { printf 'grant_type=password&client_id=trino&scope=openid&username=%s&' "$user"
    printf 'client_secret=%s&password=' "$secret"
    python3 -I -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip()),end="")' < "$pwfile"
  } | curl -fsS --noproxy '*' --cacert "$ca" --resolve "keycloak.${BASE_DOMAIN}:443:${DP_INGRESS_IP}" \
        --data-binary @- "${DP_KEYCLOAK_URL}/realms/lakehouse/protocol/openid-connect/token" | jq -r .access_token
}

# dp_trino_user <user> <token> <ca> <sql...> : query as a Keycloak user with a bearer token
dp_trino_user() {
  local user="$1" token="$2" ca="$3"; shift 3
  TRINO_URL="$DP_TRINO_URL" TRINO_CA="$ca" TRINO_USER="$user" TRINO_TOKEN="$token" TRINO_RESOLVE="$DP_INGRESS_IP" \
    python3 -I "${REPO_ROOT}/scripts/lib/trino_query.py" "$*"
}

# dp_dagster_graphql : GraphQL request (JSON body on stdin) against the webserver,
# executed inside the webserver pod (the webserver is only reachable from the proxy)
dp_dagster_graphql() {
  kubectl -n orchestration exec -i deploy/dagster-dagster-webserver -c dagster -- python -c '
import sys, urllib.request
req = urllib.request.Request("http://127.0.0.1:80/graphql", data=sys.stdin.buffer.read(), headers={"Content-Type": "application/json"})
print(urllib.request.urlopen(req, timeout=60).read().decode())'
}

# dp_dagster_launch <job> [partition] -> run id
dp_dagster_launch() {
  local job="$1" partition="${2:-}"
  jq -n --arg job "$job" --arg p "$partition" '{
    query: "mutation($p: ExecutionParams!) { launchRun(executionParams: $p) { __typename ... on LaunchRunSuccess { run { runId } } ... on PythonError { message } ... on RunConfigValidationInvalid { errors { message } } ... on InvalidSubsetError { message } } }",
    variables: { p: {
      selector: { repositoryLocationName: "lakehouse", repositoryName: "__repository__", jobName: $job },
      runConfigData: {},
      executionMetadata: { tags: (if $p == "" then [] else [{key: "dagster/partition", value: $p}] end) }
    } } }' | dp_dagster_graphql | jq -r '.data.launchRun | if .__typename == "LaunchRunSuccess" then .run.runId else error(tostring) end'
}

# dp_dagster_status <run id> -> QUEUED|STARTING|STARTED|SUCCESS|FAILURE|CANCELED
dp_dagster_status() {
  jq -n --arg id "$1" '{query: "query($id: ID!) { runOrError(runId: $id) { ... on Run { status } } }", variables: {id: $id}}' \
    | dp_dagster_graphql | jq -r '.data.runOrError.status'
}

# dp_dagster_wait <run id> <timeout seconds> : waits for a terminal state, fails unless SUCCESS
dp_dagster_wait() {
  local id="$1" timeout="$2" start status
  start="$(date +%s)"
  while :; do
    status="$(dp_dagster_status "$id")"
    case "$status" in
      SUCCESS) return 0 ;;
      FAILURE|CANCELED) err "run ${id}: ${status}"; return 1 ;;
    esac
    (( $(date +%s) - start > timeout )) && { err "run ${id}: still ${status} after ${timeout}s"; return 1; }
    sleep 15
  done
}
