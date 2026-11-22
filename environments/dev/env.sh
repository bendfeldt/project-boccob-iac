# shellcheck shell=bash
# Non-secret settings for the scripts (sourced by scripts/lib/common.sh).
# dev = k3s server inside a Podman container + Zot as a Podman container.
export CLUSTER_NAME="boccob-dev"
export CLUSTER_MODE="podman"
export BASE_DOMAIN="dev.lakehouse.internal"
export REGISTRY_HOST="registry.dev.lakehouse.internal:5000"

# podman-mode only -------------------------------------------------------------
export DEV_API_PORT="${DEV_API_PORT:-6443}"       # 127.0.0.1:<port> -> kube-apiserver
# Ingress ports on this machine. Linux: 443/80 directly (root). macOS (podman machine):
# the non-privileged 8443/8080 on the Mac's loopback, forwarded by podman's gvproxy;
# `make macos-ports` adds a pf redirect 127.0.0.1:443 -> 8443 and :80 -> 8080.
if [[ "${CLUSTER_RUNTIME:-native}" == "podman-machine" ]]; then
  export DEV_HTTPS_PORT="${DEV_HTTPS_PORT:-8443}"
  export DEV_HTTP_PORT="${DEV_HTTP_PORT:-8080}"
else
  export DEV_HTTPS_PORT="${DEV_HTTPS_PORT:-443}"  # 127.0.0.1:<port> -> Traefik websecure
  export DEV_HTTP_PORT="${DEV_HTTP_PORT:-80}"     # 127.0.0.1:<port> -> Traefik web (redirects)
fi
# Port in the public URLs (Keycloak issuer, OIDC redirects, Traefik entry points; one
# fixed value, as Keycloak's hostname guidance requires):
#   443  (default) https://<svc>.dev.lakehouse.internal  - Linux, or macOS WITH the pf redirect
#   8443 https://<svc>.dev.lakehouse.internal:8443       - macOS without the redirect
# Changing it needs `make cluster-up` and `make deploy` (00-bootstrap, 13-identity, 21/22/30).
export DEV_PUBLIC_HTTPS_PORT="${DEV_PUBLIC_HTTPS_PORT:-443}"
if [[ "$DEV_PUBLIC_HTTPS_PORT" == "443" ]]; then
  export DEV_PUBLIC_HTTP_PORT="${DEV_PUBLIC_HTTP_PORT:-80}"
else
  export DEV_PUBLIC_HTTP_PORT="${DEV_PUBLIC_HTTP_PORT:-${DEV_HTTP_PORT}}"
fi
export DEV_REGISTRY_PORT="${DEV_REGISTRY_PORT:-5000}"
# kubelet tweaks for the dev node container (never for test/prod hosts):
#  - eviction: the default "nodefs.available<10%" is relative to the size of
#    the host filesystem, which on a shared build machine is far more than a
#    dev cluster may ever use -> absolute thresholds instead;
#  - cgroup v1 container hosts are rejected by kubelet >= 1.35 unless told otherwise.
K3S_EXTRA_KUBELET_ARGS="eviction-hard=memory.available<100Mi,nodefs.available<1Gi,imagefs.available<1Gi image-gc-high-threshold=98 image-gc-low-threshold=95"
# (a podman machine runs Fedora CoreOS: always cgroup v2)
if [[ "${CLUSTER_RUNTIME:-native}" == "native" && "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" != "cgroup2fs" ]]; then
  K3S_EXTRA_KUBELET_ARGS+=" fail-cgroupv1=false"
fi
export K3S_EXTRA_KUBELET_ARGS
# manage a marked block in /etc/hosts so <svc>.dev.lakehouse.internal resolves on this machine
# (Linux: on by default, the scripts run as root; macOS: opt-in, the edit needs sudo)
if [[ "${CLUSTER_RUNTIME:-native}" == "podman-machine" ]]; then
  export DEV_MANAGE_ETC_HOSTS="${DEV_MANAGE_ETC_HOSTS:-0}"
else
  export DEV_MANAGE_ETC_HOSTS="${DEV_MANAGE_ETC_HOSTS:-1}"
fi
# podman machine (macOS): its name (empty = the default machine) and the VM
# directory that receives the files bind-mounted into the node/registry containers
export PODMAN_MACHINE="${PODMAN_MACHINE:-}"
export DEV_MACHINE_DIR="${DEV_MACHINE_DIR:-/var/lib/boccob/dev}"
# address the dev ports are published on (machine: forwarded to the Mac by gvproxy)
export DEV_PUBLISH_ADDR="${DEV_PUBLISH_ADDR:-127.0.0.1}"
export DEV_INGRESS_HOSTS="keycloak openbao s3 s3-console trino polaris dagster grafana"

# OpenBao init: 1 key share in dev (kept in ${STATE_DIR}/openbao/, never in git)
export OPENBAO_KEY_SHARES=1
export OPENBAO_KEY_THRESHOLD=1
export OPENBAO_REPLICAS=1
# state encryption key provider: pbkdf2 passphrase generated into ${STATE_DIR}
export STATE_ENCRYPTION="pbkdf2"

# signature verification + Trivy scan while mirroring (scripts/airgap/mirror.sh) are
# always on for test/prod; dev skips them by default (needs sigstore + the Trivy DB
# online; dev images never leave this machine). SKIP_SUPPLY_CHAIN=0 turns them on.
export SKIP_SUPPLY_CHAIN="${SKIP_SUPPLY_CHAIN:-1}"

# optional components not deployed on dev (Grafana, ~480 MB): not mirrored, not checked
export MIRROR_EXCLUDE_GROUPS="${MIRROR_EXCLUDE_GROUPS-observability-ui}"
