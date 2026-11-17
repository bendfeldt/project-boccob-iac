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

first="${servers[0]}"
step "first server ${first} (cluster-init)"
push "$first"
run "$first" "cd /root/${dir} && ./host-install.sh server --cluster-init"

step "fetch kubeconfig and join token"
run "$first" "cat /etc/rancher/k3s/k3s.yaml" | sed "s|https://127.0.0.1:6443|${url}|" | write_secret_file "$KUBECONFIG"
token_tmp="$(mktemp)"; trap 'rm -f "$token_tmp"' EXIT
run "$first" "cat /var/lib/rancher/k3s/server/token" | write_secret_file "$token_tmp"

join() { # join <host> <role>
  step "$2 $1"
  push "$1"
  scp "${ssh_opts[@]}" "$token_tmp" "${K3S_SSH_USER}@$1:/root/k3s-token"
  run "$1" "chmod 600 /root/k3s-token && cd /root/${dir} && K3S_TOKEN_FILE=/root/k3s-token ./host-install.sh $2 --join '${url}'"
}
for h in "${servers[@]:1}"; do join "$h" server; done
for h in "${agents[@]}"; do join "$h" agent; done

wait_for 300 "all nodes Ready" bash -c '! kubectl get nodes --no-headers | grep -v " Ready "'
kubectl get nodes -o wide >&2
log "cluster ${CLUSTER_NAME} is up. export KUBECONFIG=${KUBECONFIG}"
