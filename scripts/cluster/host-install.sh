#!/usr/bin/env bash
# Air-gap install of a hardened k3s node (test/prod). Runs ON THE NODE as root,
# from the unpacked node bundle (scripts/airgap/node-bundle.sh).
#
#   first server : ./host-install.sh server --cluster-init
#   more servers : K3S_TOKEN_FILE=/root/k3s-token ./host-install.sh server --join https://<api-endpoint>:6443
#   agents       : K3S_TOKEN_FILE=/root/k3s-token ./host-install.sh agent  --join https://<api-endpoint>:6443
#
# HA = 3 (or 5) servers with embedded etcd behind a fixed registration address
# (K3S_API_ENDPOINT: VIP, load balancer or round-robin DNS).
# The join token is read from K3S_TOKEN_FILE (mode 0600); the first server
# generates it at /var/lib/rancher/k3s/server/token.
#
# NOTE: this script cannot be exercised in the build sandbox (no systemd hosts);
# it is shellcheck-clean and mirrors the configuration the dev cluster runs with.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/k3s-config.sh
source "${HERE}/lib/k3s-config.sh"
# shellcheck source=/dev/null
source "${HERE}/bundle.env"

role="${1:?usage: host-install.sh server|agent [--cluster-init | --join <url>]}"; shift
cluster_init=false; join_url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-init) cluster_init=true ;;
    --join) join_url="${2:?--join needs a URL}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$(id -u)" == "0" ]] || { echo "must run as root" >&2; exit 1; }
[[ "$role" == "server" || "$role" == "agent" ]] || { echo "role must be server or agent" >&2; exit 2; }
if [[ "$cluster_init" == "false" && -z "$join_url" ]]; then echo "need --cluster-init or --join <url>" >&2; exit 2; fi
if [[ "$(stat -fc %T /sys/fs/cgroup)" != "cgroup2fs" ]]; then echo "cgroup v2 is required on test/prod hosts" >&2; exit 1; fi
# the bundle carries binaries and images for one architecture (node-bundle.sh, CLUSTER_ARCH)
case "$(uname -m)" in
  x86_64|amd64) node_arch=amd64 ;;
  aarch64|arm64) node_arch=arm64 ;;
  *) echo "unsupported node architecture $(uname -m): x64 (x86_64/amd64) or arm64 (aarch64) only" >&2; exit 1 ;;
esac
bundle_arch="${K3S_ARCH:-amd64}"   # bundles built before K3S_ARCH existed were amd64
if [[ "$node_arch" != "$bundle_arch" ]]; then
  echo "this node is ${node_arch} but the bundle is for ${bundle_arch}: build it with CLUSTER_ARCH=${node_arch}" >&2; exit 1
fi

echo "==> verify bundle"
( cd "$HERE" && sha256sum --quiet -c SHA256SUMS )

echo "==> kernel parameters (protect-kernel-defaults)"
k3s_required_sysctls > /etc/sysctl.d/90-kubelet.conf
sysctl -q -p /etc/sysctl.d/90-kubelet.conf

echo "==> binaries and images"
install -m 0755 "${HERE}/k3s" /usr/local/bin/k3s
install -d -m 0755 /var/lib/rancher/k3s/agent/images
install -m 0644 "${HERE}/k3s-airgap-images-${bundle_arch}.tar.zst" /var/lib/rancher/k3s/agent/images/

echo "==> configuration"
install -d -m 0700 /etc/rancher/k3s "${K3S_HARDENING_DIR}"
install -m 0600 "${HERE}/hardening/"* "${K3S_HARDENING_DIR}/"
node_name="$(hostname -f)"
if [[ "$role" == "server" ]]; then
  # CIS 1.1.12: etcd data directory owned by a dedicated etcd user is not
  # applicable to embedded etcd (k3s manages it as root, mode 0700).
  install -d -m 0700 "${K3S_AUDIT_LOG_DIR}"
  sans="${node_name}"
  if [[ -n "${K3S_API_ENDPOINT:-}" ]]; then sans="${K3S_API_ENDPOINT},${sans}"; fi
  render_k3s_server_config "$node_name" "$cluster_init" "$sans" "$join_url" > /etc/rancher/k3s/config.yaml
  # control-plane nodes do not run workloads when dedicated agents exist
  if [[ "${K3S_SERVER_NOSCHEDULE:-0}" == "1" ]]; then
    printf 'node-taint:\n  - "node-role.kubernetes.io/control-plane:NoSchedule"\n' >> /etc/rancher/k3s/config.yaml
  fi
else
  render_k3s_agent_config "$node_name" "$join_url" > /etc/rancher/k3s/config.yaml
fi
render_registries_yaml "$REGISTRY_HOST" "https://${REGISTRY_HOST}" "${K3S_HARDENING_DIR}/registry-ca.crt" > /etc/rancher/k3s/registries.yaml
chmod 0600 /etc/rancher/k3s/config.yaml /etc/rancher/k3s/registries.yaml

if [[ -n "$join_url" ]]; then
  : "${K3S_TOKEN_FILE:?K3S_TOKEN_FILE must point to the cluster join token}"
  [[ "$(stat -c %a "$K3S_TOKEN_FILE")" == "600" ]] || { echo "K3S_TOKEN_FILE must have mode 0600" >&2; exit 1; }
  printf 'token-file: "%s"\n' "$K3S_TOKEN_FILE" >> /etc/rancher/k3s/config.yaml
fi

echo "==> install k3s ${K3S_VERSION} (${role}), no downloads"
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_EXEC="$role" sh "${HERE}/k3s-install.sh"

if [[ "$role" == "server" ]]; then
  echo "==> wait for the API"
  for _ in $(seq 1 60); do
    if k3s kubectl get --raw /readyz >/dev/null 2>&1; then break; fi
    sleep 5
  done
  k3s kubectl get nodes
  chmod 0600 /etc/rancher/k3s/k3s.yaml
  if [[ "$cluster_init" == "true" ]]; then
    echo "join token for further nodes: /var/lib/rancher/k3s/server/token (transfer securely, mode 0600)"
  fi
fi
echo "done: ${node_name} (${role})"
