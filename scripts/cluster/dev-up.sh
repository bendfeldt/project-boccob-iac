#!/usr/bin/env bash
# dev cluster: single hardened k3s server inside a Podman container, on a
# dedicated podman network shared with the Zot bootstrap registry.
# The node has no internet access by design: every image comes from Zot
# through /etc/rancher/k3s/registries.yaml.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
# shellcheck source=../lib/k3s-config.sh
source "${REPO_ROOT}/scripts/lib/k3s-config.sh"
load_env "${1:-${ENV:-}}"
[[ "$CLUSTER_MODE" == "podman" ]] || die "dev-up.sh only handles CLUSTER_MODE=podman"
require_cmd podman kubectl jq skopeo

NODE="${CLUSTER_NAME}-server-0"
CFG="${STATE_DIR}/k3s"
mkdir -p "${CFG}/etc/hardening"; chmod 700 "$CFG"

step "registry"
"${REPO_ROOT}/scripts/cluster/registry-up.sh" "$ENV"
if [[ "${SKIP_MIRROR:-0}" != "1" ]]; then
  if [[ -n "${BUNDLE_DIR:-}" ]]; then
    MIRROR_GROUPS=cluster "${REPO_ROOT}/scripts/airgap/mirror.sh" load "$ENV" "$BUNDLE_DIR"
  else
    MIRROR_GROUPS=cluster "${REPO_ROOT}/scripts/airgap/mirror.sh" sync "$ENV"
  fi
fi

step "kernel parameters required by protect-kernel-defaults"
while IFS='=' read -r key want; do
  got="$(sysctl -n "$key")"
  if [[ "$got" != "$want" ]]; then
    log "sysctl ${key}: ${got} -> ${want}"
    sysctl -q -w "${key}=${want}" || die "cannot set ${key}=${want} on the podman host"
  fi
done < <(k3s_required_sysctls)

step "render hardened k3s configuration"
render_k3s_server_config "$NODE" false "127.0.0.1,localhost,${NODE},k3s.${BASE_DOMAIN}" > "${CFG}/etc/config.yaml"
render_registries_yaml "$REGISTRY_HOST" "https://${REGISTRY_HOST}" "${K3S_HARDENING_DIR}/registry-ca.crt" > "${CFG}/etc/registries.yaml"
cp "${REPO_ROOT}/scripts/cluster/config/audit-policy.yaml" "${REPO_ROOT}/scripts/cluster/config/admission.yaml" "${CFG}/etc/hardening/"
cp "${REGISTRY_CA_FILE}" "${CFG}/etc/hardening/registry-ca.crt"
# podman would copy the host's /etc/hosts (incl. our 127.0.0.1 dev block) into
# the node; give it a clean one so the registry name resolves via podman DNS.
printf '127.0.0.1 localhost\n::1 localhost\n' > "${CFG}/etc/hosts"
# Fixed node address: NetworkPolicies that allow the Kubernetes API reference
# the node IP, so it must survive a re-creation of the container.
subnet="$(podman network inspect "${CLUSTER_NAME}" | jq -r '.[0].subnets[0].subnet')"
node_ip="${DEV_NODE_IP:-${subnet%.*}.10}"

# Container hosts without CAP_SYS_RESOURCE (some sandboxes / nested setups)
# cannot lower oom_score_adj, which runc needs for the pause container
# (-998). containerd can clamp it to its own value instead.
extra_mounts=()
: > "${CFG}/etc/containerd-dropin.toml"
if ! ( echo -1 > /proc/self/oom_score_adj ) 2>/dev/null; then
  warn "host lacks CAP_SYS_RESOURCE: enabling containerd restrict_oom_score_adj (dev only)"
  printf "[plugins.'io.containerd.cri.v1.runtime']\n  restrict_oom_score_adj = true\n" > "${CFG}/etc/containerd-dropin.toml"
  extra_mounts+=(-v "${CFG}/etc/containerd-dropin.toml:/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/10-boccob-dev.toml:ro")
fi
cfg_sum="$(echo "$node_ip" | cat - "${CFG}/etc/containerd-dropin.toml" "${CFG}/etc/hosts" "${CFG}/etc/config.yaml" "${CFG}/etc/registries.yaml" "${CFG}/etc/hardening/"* | sha256sum | awk '{print $1}')"

step "k3s node container ${NODE}"
k3s_ref="$(image_zot_digest_ref k3s)"
if ! podman image exists "$k3s_ref"; then
  # the host pulls the node image from Zot as well (same path prod nodes use)
  skopeo copy --quiet --preserve-digests "docker://${k3s_ref}" "containers-storage:${k3s_ref}"
fi

if podman_container_alive "$NODE"; then
  old_sum="$(podman inspect -f '{{ index .Config.Labels "boccob.config-sha256" }}' "$NODE")"
  if [[ "$old_sum" != "$cfg_sum" ]]; then
    warn "k3s configuration changed; recreating the node container (data volumes are kept)"
    podman rm -f "$NODE" >/dev/null
  fi
else
  # stopped or stale: recreate from the persistent volumes
  podman rm -f "$NODE" >/dev/null 2>&1 || true
fi
if ! podman container exists "$NODE"; then
  for v in data kubelet log; do
    podman volume exists "${NODE}-${v}" || podman volume create "${NODE}-${v}" >/dev/null
  done
  # --privileged: k3s needs cgroup, mount and netfilter access (same as k3d/kind).
  podman run -d --name "$NODE" --hostname "$NODE" \
    --privileged \
    --network "${CLUSTER_NAME}" --ip "${node_ip}" --no-hosts \
    -v "${CFG}/etc/hosts:/etc/hosts:ro" \
    --label "boccob.config-sha256=${cfg_sum}" \
    -p "127.0.0.1:${DEV_API_PORT}:6443" \
    -p "127.0.0.1:${DEV_HTTPS_PORT}:443" \
    -p "127.0.0.1:${DEV_HTTP_PORT}:80" \
    --tmpfs /run --tmpfs /var/run \
    -v "${NODE}-data:/var/lib/rancher/k3s" \
    -v "${NODE}-kubelet:/var/lib/kubelet" \
    -v "${NODE}-log:/var/log" \
    -v "${CFG}/etc/config.yaml:/etc/rancher/k3s/config.yaml:ro" \
    -v "${CFG}/etc/registries.yaml:/etc/rancher/k3s/registries.yaml:ro" \
    -v "${CFG}/etc/hardening:${K3S_HARDENING_DIR}:ro" \
    "${extra_mounts[@]}" \
    --restart always \
    "$k3s_ref" server >/dev/null
fi

step "kubeconfig -> ${KUBECONFIG}"
wait_for 120 "k3s kubeconfig" podman exec "$NODE" test -s /etc/rancher/k3s/k3s.yaml
podman exec "$NODE" cat /etc/rancher/k3s/k3s.yaml \
  | sed -e "s|https://127.0.0.1:6443|https://127.0.0.1:${DEV_API_PORT}|" -e "s|: default$|: ${CLUSTER_NAME}|" \
  | write_secret_file "$KUBECONFIG"

step "wait for node and system pods"
wait_for 180 "kube-apiserver" kubectl get --raw /readyz
wait_for 180 "node Ready" kubectl wait --for=condition=Ready "node/${NODE}" --timeout=5s
wait_for 300 "coredns" kubectl -n kube-system rollout status deploy/coredns --timeout=5s
wait_for 300 "traefik" kubectl -n kube-system rollout status deploy/traefik --timeout=5s
kubectl get nodes -o wide >&2

# OpenBao seals itself whenever its pod restarts. In dev the single unseal key
# is on this machine, so bring it back automatically (test/prod: custodians run
# `make openbao-unseal`).
if kubectl -n secrets get statefulset openbao >/dev/null 2>&1 && [[ -f "${STATE_DIR}/openbao/init.json" ]]; then
  step "unseal OpenBao (dev)"
  # after a host restart openbao-0 may still be (re)starting: wait until its
  # container runs, then retry the unseal a few times
  wait_for 300 "openbao-0 container running" bash -c \
    "kubectl -n secrets get pod openbao-0 -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' | grep -q ."
  for attempt in 1 2 3 4 5; do
    "${REPO_ROOT}/scripts/openbao/init.sh" "$ENV" --unseal && break
    (( attempt < 5 )) || die "OpenBao unseal failed 5 times (make openbao-unseal ENV=${ENV})"
    warn "unseal attempt ${attempt} failed, retrying in 15 s"
    sleep 15
  done
  # External Secrets marks the read store invalid while OpenBao is sealed; make
  # it re-validate now instead of at its next periodic reconcile
  kubectl annotate clustersecretstore openbao openbao-push "boccob.io/revalidate=$(date +%s)" --overwrite >/dev/null 2>&1 || true
fi
log "dev cluster is up. export KUBECONFIG=${KUBECONFIG}"
