# shellcheck shell=bash
# Non-secret settings for the scripts (sourced by scripts/lib/common.sh).
# dev = k3s server inside a Podman container + Zot as a Podman container.
export CLUSTER_NAME="boccob-dev"
export CLUSTER_MODE="podman"
export BASE_DOMAIN="dev.lakehouse.internal"
export REGISTRY_HOST="registry.dev.lakehouse.internal:5000"

# podman-mode only -------------------------------------------------------------
export DEV_API_PORT="${DEV_API_PORT:-6443}"       # 127.0.0.1:<port> -> kube-apiserver
export DEV_HTTPS_PORT="${DEV_HTTPS_PORT:-443}"    # 127.0.0.1:<port> -> Traefik websecure
export DEV_HTTP_PORT="${DEV_HTTP_PORT:-80}"       # 127.0.0.1:<port> -> Traefik web (redirects)
export DEV_REGISTRY_PORT="${DEV_REGISTRY_PORT:-5000}"
# kubelet tweaks for the dev node container (never for test/prod hosts):
#  - eviction: the default "nodefs.available<10%" is relative to the size of
#    the host filesystem, which on a shared build machine is far more than a
#    dev cluster may ever use -> absolute thresholds instead;
#  - cgroup v1 container hosts are rejected by kubelet >= 1.35 unless told otherwise.
K3S_EXTRA_KUBELET_ARGS="eviction-hard=memory.available<100Mi,nodefs.available<1Gi,imagefs.available<1Gi image-gc-high-threshold=98 image-gc-low-threshold=95"
if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" != "cgroup2fs" ]]; then
  K3S_EXTRA_KUBELET_ARGS+=" fail-cgroupv1=false"
fi
export K3S_EXTRA_KUBELET_ARGS
# manage a marked block in /etc/hosts so <svc>.dev.lakehouse.internal resolves on this machine
export DEV_MANAGE_ETC_HOSTS="${DEV_MANAGE_ETC_HOSTS:-1}"
export DEV_INGRESS_HOSTS="keycloak openbao s3 s3-console trino polaris dagster grafana"

# OpenBao init: 1 key share in dev (kept in ${STATE_DIR}/openbao/, never in git)
export OPENBAO_KEY_SHARES=1
export OPENBAO_KEY_THRESHOLD=1
export OPENBAO_REPLICAS=1
# state encryption key provider: pbkdf2 passphrase generated into ${STATE_DIR}
export STATE_ENCRYPTION="pbkdf2"
