# shellcheck shell=bash
# Helpers for the data-plane platform checks (scripts/verify.d/20-data-plane.sh).
# Source after load_env (needs BASE_DOMAIN).

# ingress address as seen from this machine (dev: loopback of the node container)
DP_INGRESS_IP="${INGRESS_IP:-127.0.0.1}"
# port of the ingress on this machine: 443 on Linux; on macOS the forwarded 8443 (it
# answers with and without the pf redirect of make macos-ports)
DP_INGRESS_PORT="${DEV_HTTPS_PORT:-443}"
DP_PORT_SUFFIX=""
[[ "$DP_INGRESS_PORT" == "443" ]] || DP_PORT_SUFFIX=":${DP_INGRESS_PORT}"
DP_TRINO_URL="https://trino.${BASE_DOMAIN}${DP_PORT_SUFFIX}"

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

# dp_dagster_graphql : GraphQL request (JSON body on stdin) against the webserver,
# executed inside the webserver pod (the webserver is only reachable from the proxy)
dp_dagster_graphql() {
  kubectl -n orchestration exec -i deploy/dagster-dagster-webserver -c dagster -- python -c '
import sys, urllib.request
req = urllib.request.Request("http://127.0.0.1:80/graphql", data=sys.stdin.buffer.read(), headers={"Content-Type": "application/json"})
print(urllib.request.urlopen(req, timeout=60).read().decode())'
}
