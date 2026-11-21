#!/usr/bin/env bash
# dev cluster: single hardened k3s server inside a Podman container, on a
# dedicated podman network shared with the Zot bootstrap registry.
# The node has no internet access by design: every image comes from Zot
# through /etc/rancher/k3s/registries.yaml.
#
# CLUSTER_RUNTIME=native (Linux, run as root): containers on this machine.
# CLUSTER_RUNTIME=podman-machine (macOS): containers in a ROOTFUL podman machine
# (make machine-init). Kernel settings and the files bind-mounted into the node
# are applied inside the VM (podman machine ssh); ports are published in the VM
# and forwarded to the Mac by podman's gvproxy. The node image architecture is
# the VM's (arm64 on Apple Silicon): CLUSTER_ARCH selects the locked digests.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
# shellcheck source=../lib/k3s-config.sh
source "${REPO_ROOT}/scripts/lib/k3s-config.sh"
load_env "${1:-${ENV:-}}"
[[ "$CLUSTER_MODE" == "podman" ]] || die "dev-up.sh only handles CLUSTER_MODE=podman"
require_brew_prereqs
require_cmd podman kubectl jq skopeo
require_rootful_podman
runtime="$(cluster_runtime)"
ensure_cluster_arch
log "runtime: ${runtime}, node architecture: linux/${CLUSTER_ARCH}"

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
if [[ "$runtime" == "podman-machine" ]]; then
  # in the VM; also persisted there so they survive a machine restart
  k3s_required_sysctls | container_host_write_file /etc/sysctl.d/90-boccob-k3s.conf 0644
  container_host_exec "sysctl -q -p /etc/sysctl.d/90-boccob-k3s.conf" || die "cannot set the kernel parameters in the podman machine"
else
  while IFS='=' read -r key want; do
    got="$(sysctl -n "$key")"
    if [[ "$got" != "$want" ]]; then
      log "sysctl ${key}: ${got} -> ${want}"
      sysctl -q -w "${key}=${want}" || die "cannot set ${key}=${want} on the podman host"
    fi
  done < <(k3s_required_sysctls)
fi

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
dropin=false
: > "${CFG}/etc/containerd-dropin.toml"
if ! container_host_exec 'echo -1 > /proc/self/oom_score_adj' 2>/dev/null; then
  warn "host lacks CAP_SYS_RESOURCE: enabling containerd restrict_oom_score_adj (dev only)"
  printf "[plugins.'io.containerd.cri.v1.runtime']\n  restrict_oom_score_adj = true\n" > "${CFG}/etc/containerd-dropin.toml"
  dropin=true
fi
cfg_sum="$(echo "$node_ip" | cat - "${CFG}/etc/containerd-dropin.toml" "${CFG}/etc/hosts" "${CFG}/etc/config.yaml" "${CFG}/etc/registries.yaml" "${CFG}/etc/hardening/"* | sha256_stream | awk '{print $1}')"
# Traefik's ServiceLB listens on the node at the PUBLIC ports (Traefik exposedPort,
# stack 00-bootstrap); they differ from 443/80 only with DEV_PUBLIC_HTTPS_PORT set
node_https="${DEV_PUBLIC_HTTPS_PORT:-443}" node_http="${DEV_PUBLIC_HTTP_PORT:-80}"
if [[ "$node_https" != "443" || "$DEV_HTTPS_PORT" != "443" ]]; then
  # port mapping is part of the container definition: recreate when it changes
  # (only appended when not the Linux default, so existing nodes keep their hash)
  cfg_sum="$(printf '%s %s:%s %s:%s' "$cfg_sum" "$DEV_HTTPS_PORT" "$node_https" "$DEV_HTTP_PORT" "$node_http" | sha256_stream | awk '{print $1}')"
fi
# bind mounts are resolved on the container host: native = ${CFG}/etc itself,
# podman machine = a root-owned copy in the VM
etc="$(container_host_sync_dir "${CFG}/etc" "${DEV_MACHINE_DIR:-/var/lib/boccob/${ENV}}/k3s-etc")"
if $dropin; then
  extra_mounts+=(-v "${etc}/containerd-dropin.toml:/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/10-boccob-dev.toml:ro")
fi

step "k3s node container ${NODE}"
k3s_ref="$(image_zot_digest_ref k3s)"
if ! podman image exists "$k3s_ref"; then
  # the host pulls the node image from Zot as well (same path prod nodes use)
  if [[ "$runtime" == "podman-machine" ]]; then
    # the VM's podman (registry name + CA set up by registry-up.sh)
    podman pull -q "$k3s_ref" >/dev/null
  else
    skopeo copy --quiet --preserve-digests "docker://${k3s_ref}" "containers-storage:${k3s_ref}"
  fi
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
    -v "${etc}/hosts:/etc/hosts:ro" \
    --label "boccob.config-sha256=${cfg_sum}" \
    -p "${DEV_PUBLISH_ADDR:-127.0.0.1}:${DEV_API_PORT}:6443" \
    -p "${DEV_PUBLISH_ADDR:-127.0.0.1}:${DEV_HTTPS_PORT}:${node_https}" \
    -p "${DEV_PUBLISH_ADDR:-127.0.0.1}:${DEV_HTTP_PORT}:${node_http}" \
    --tmpfs /run --tmpfs /var/run \
    -v "${NODE}-data:/var/lib/rancher/k3s" \
    -v "${NODE}-kubelet:/var/lib/kubelet" \
    -v "${NODE}-log:/var/log" \
    -v "${etc}/config.yaml:/etc/rancher/k3s/config.yaml:ro" \
    -v "${etc}/registries.yaml:/etc/rancher/k3s/registries.yaml:ro" \
    -v "${etc}/hardening:${K3S_HARDENING_DIR}:ro" \
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
if [[ "$runtime" == "podman-machine" ]]; then
  port_listening 127.0.0.1 "${DEV_HTTPS_PORT}" \
    || warn "nothing answers on 127.0.0.1:${DEV_HTTPS_PORT} on this Mac: podman (gvproxy) did not forward the ingress port (podman machine stop/start)"
  if [[ "${DEV_PUBLIC_HTTPS_PORT:-443}" == "443" ]] && ! "${REPO_ROOT}/scripts/cluster/macos-ports.sh" "$ENV" check >/dev/null 2>&1; then
    warn "public URLs are https://<svc>.${BASE_DOMAIN} (port 443) but the pf redirect 443 -> ${DEV_HTTPS_PORT} is not active:"
    warn "make macos-ports ENV=${ENV} (sudo), or deploy with DEV_PUBLIC_HTTPS_PORT=${DEV_HTTPS_PORT} (docs/getting-started.md, Part C)"
  fi
fi

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
