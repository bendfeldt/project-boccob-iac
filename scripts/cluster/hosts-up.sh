#!/usr/bin/env bash
# test/prod: install k3s on the hosts listed in environments/<env>/env.sh over
# SSH, from the node bundle. First server initialises embedded etcd, the other
# servers and the agents join through K3S_API_ENDPOINT.
#
#   scripts/cluster/hosts-up.sh <env>
# Needs: node bundle tar (scripts/airgap/node-bundle.sh), SSH access as
# K3S_SSH_USER with root rights. NOT exercised in the build sandbox (shellcheck only).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
[[ "$CLUSTER_MODE" == "hosts" ]] || die "hosts-up.sh only handles CLUSTER_MODE=hosts"
require_cmd ssh scp
bundle="${NODE_BUNDLE:-${BOCCOB_CACHE_DIR}/node-bundle-${ENV}.tar}"
[[ -f "$bundle" ]] || die "node bundle not found: ${bundle} (run: make node-bundle ENV=${ENV})"
read -ra servers <<<"${K3S_SERVERS}"
read -ra agents <<<"${K3S_AGENTS:-}"
(( ${#servers[@]} % 2 == 1 )) || die "embedded etcd needs an odd number of servers (got ${#servers[@]})"
dir="$(basename "${bundle%.tar}")"
url="https://${K3S_API_ENDPOINT}:6443"
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes)

push() { # push <host>
  scp "${ssh_opts[@]}" "$bundle" "${K3S_SSH_USER}@$1:/root/"
  # shellcheck disable=SC2029  # expanded locally on purpose
  ssh "${ssh_opts[@]}" "${K3S_SSH_USER}@$1" "cd /root && rm -rf '${dir}' && tar -xf '$(basename "$bundle")'"
}
run() { # run <host> <command>
  # shellcheck disable=SC2029  # expanded locally on purpose
  ssh "${ssh_opts[@]}" "${K3S_SSH_USER}@$1" "$2"
}

# Agents join with their own token (k3s agent-token): a compromised worker cannot
# join a server (etcd member). Kept for re-runs and node additions (0600).
agent_token="${STATE_DIR}/k3s/agent-token"
[[ -f "$agent_token" ]] || random_secret 32 | write_secret_file "$agent_token"
put_agent_token() { # every server gets the agent token for agent-token-file
  scp "${ssh_opts[@]}" "$agent_token" "${K3S_SSH_USER}@$1:/root/k3s-agent-token"
  run "$1" "chmod 600 /root/k3s-agent-token"
}

first="${servers[0]}"
step "first server ${first} (cluster-init)"
push "$first"
put_agent_token "$first"
run "$first" "cd /root/${dir} && K3S_AGENT_TOKEN_FILE=/root/k3s-agent-token ./host-install.sh server --cluster-init"

step "fetch kubeconfig and server join token"
run "$first" "cat /etc/rancher/k3s/k3s.yaml" | sed "s|https://127.0.0.1:6443|${url}|" | write_secret_file "$KUBECONFIG"
token_tmp="$(mktemp)" agent_tmp="$(mktemp)"; trap 'rm -f "$token_tmp" "$agent_tmp"' EXIT
run "$first" "cat /var/lib/rancher/k3s/server/token" | write_secret_file "$token_tmp"
# the full form (K10<CA hash>::...) of the agent token: agents pin the cluster CA
run "$first" "cat /var/lib/rancher/k3s/server/agent-token" | write_secret_file "$agent_tmp"

join() { # join <host> <role>: servers get the server token, agents only the agent token
  local token="$token_tmp" env=""
  step "$2 $1"
  push "$1"
  if [[ "$2" == server ]]; then put_agent_token "$1"; env="K3S_AGENT_TOKEN_FILE=/root/k3s-agent-token "
  else token="$agent_tmp"; fi
  scp "${ssh_opts[@]}" "$token" "${K3S_SSH_USER}@$1:/root/k3s-token"
  run "$1" "chmod 600 /root/k3s-token && cd /root/${dir} && ${env}K3S_TOKEN_FILE=/root/k3s-token ./host-install.sh $2 --join '${url}'"
}
for h in "${servers[@]:1}"; do join "$h" server; done
for h in "${agents[@]}"; do join "$h" agent; done

wait_for 300 "all nodes Ready" bash -c '! kubectl get nodes --no-headers | grep -v " Ready "'
kubectl get nodes -o wide >&2
log "cluster ${CLUSTER_NAME} is up. export KUBECONFIG=${KUBECONFIG}"
