#!/usr/bin/env bash
# Check the prerequisites of this machine for an environment (make doctor ENV=dev).
# Read-only: changes nothing. Works on Linux (x64/arm64) and macOS (Apple Silicon).
#
#   FAIL  something the scripts need (exit code 1)
#   WARN  below the recommended size, or a step you will need later
#   OK    fine
#
#   DOCTOR_NETWORK=1   also check that the internet hosts for `make lock`/mirroring answer
# shellcheck disable=SC2015 # `cond && ok .. || bad ..`: ok/soft/bad always succeed
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# load_env needs a writable state dir only; it does not touch the cluster
load_env "${1:-${ENV:-dev}}"

fails=0 warns=0
ok()   { printf '  OK    %s\n' "$*" >&2; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
soft() { printf '  WARN  %s\n' "$*" >&2; warns=$((warns + 1)); }
section() { printf '\n%s\n' "$*" >&2; }

# version_ge <have> <want> : dotted numeric compare
version_ge() {
  local IFS=. i; local -a h w
  read -ra h <<<"$1"; read -ra w <<<"$2"
  for ((i = 0; i < ${#w[@]}; i++)); do
    (( 10#${h[i]:-0} > 10#${w[i]} )) && return 0
    (( 10#${h[i]:-0} < 10#${w[i]} )) && return 1
  done
  return 0
}

os="$(host_os)"
runtime="$CLUSTER_RUNTIME"
section "machine"
if arch="$( (host_arch) 2>&1)"; then ok "this machine: ${os}/${arch}"; else bad "$arch"; arch=""; fi
ok "bash ${BASH_VERSION}"
if [[ "$CLUSTER_MODE" == "podman" ]]; then
  ok "ENV=${ENV}: CLUSTER_MODE=podman, CLUSTER_RUNTIME=${runtime}"
else
  ok "ENV=${ENV}: CLUSTER_MODE=${CLUSTER_MODE}, nodes linux/${CLUSTER_ARCH:-?} (CLUSTER_ARCH)"
fi
if [[ "$os" == "darwin" && "$runtime" != "podman-machine" ]]; then
  bad "macOS needs CLUSTER_RUNTIME=podman-machine (the default there)"
fi
if [[ "$os" == "darwin" && "$arch" == "amd64" ]]; then
  soft "Intel Mac: untested; the locked operator tools exist for darwin/arm64 only (install cosign/trivy/syft/oras with Homebrew)"
fi

if [[ "$os" == "darwin" ]]; then
  section "Homebrew (required on macOS; Brewfile)"
  if ! command -v brew >/dev/null 2>&1; then
    bad "Homebrew not found: install it (https://brew.sh), then make brew-bundle"
  else
    ok "brew: $(command -v brew)"
    missing="$(brew_missing | tr '\n' ' ')"
    if [[ -z "${missing// /}" ]]; then ok "all Brewfile formulae installed ($(brew_formulae | tr '\n' ' '))"
    else bad "missing formulae: brew install ${missing% }   (or: make brew-bundle)"; fi
    brew list --formula -1 2>/dev/null | grep -qx yq && bad "the 'yq' formula (Go yq) is installed: brew uninstall yq (python-yq provides yq)"
    gnubin="$(brew --prefix 2>/dev/null)/opt/make/libexec/gnubin"
    [[ ":$PATH:" == *":${gnubin}:"* ]] && ok "GNU make first in PATH" || soft "put ${gnubin} first in PATH (docs/getting-started.md, C.1)"
  fi
fi

section "tools"
need=(make git curl jq yq openssl helm kubectl skopeo podman)
[[ "$os" == "linux" ]] && need+=(sysctl)
for c in "${need[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then ok "${c}: $(command -v "$c")"; else bad "${c} not found"; fi
done
if command -v yq >/dev/null 2>&1; then
  if yq --version 2>&1 | grep -q 'mikefarah'; then
    bad "yq is the Go 'mikefarah' yq; the scripts need the Python yq (jq wrapper): pip/pipx install yq, or apt install yq"
  elif yq -c . <<<'a: 1' >/dev/null 2>&1; then ok "yq is the Python jq wrapper ($(yq --version 2>&1 | head -1))"
  else bad "yq does not accept jq syntax (needs the Python yq)"; fi
fi
if command -v make >/dev/null 2>&1; then
  # the Makefile needs GNU make >= 3.82 (.SHELLFLAGS); macOS ships 3.81
  v="$(make --version 2>/dev/null | sed -nE '1s/^GNU Make ([0-9.]+).*/\1/p')"
  if [[ -n "$v" ]] && version_ge "$v" 3.82; then ok "GNU make ${v}"
  else bad "make ${v:-?}: GNU make >= 3.82 needed (macOS: brew install make; PATH=\"\$(brew --prefix)/opt/make/libexec/gnubin:\$PATH\")"; fi
fi
if command -v openssl >/dev/null 2>&1; then
  v="$(openssl version 2>/dev/null)"
  if [[ "$v" == OpenSSL\ 3* ]]; then ok "${v}"
  else soft "${v}: OpenSSL 3 is the tested one (macOS LibreSSL: brew install openssl@3 and put it first in PATH)"; fi
fi
if command -v tofu >/dev/null 2>&1; then
  # exactly the locked version: the stacks accept 1.10.x only, and every operator of a
  # shared state should run the same one
  v="$(tofu version 2>/dev/null | head -1 | sed -E 's/.*v([0-9.]+).*/\1/')"
  want="$(yq -r '.binaries.tofu.platforms[] | .url' "$LOCK_FILE" 2>/dev/null | head -1 | sed -E 's#.*/download/v([0-9.]+)/.*#\1#')"
  if [[ "$v" == "$want" ]]; then ok "OpenTofu ${v} (locked)"
  else bad "OpenTofu ${v:-?} is not the locked ${want:-?}: make tools (installs it into ${BOCCOB_CACHE_DIR}/bin, first in PATH)"; fi
else bad "tofu not found: make tools"; fi
if command -v helm >/dev/null 2>&1; then
  v="$(helm version --short 2>/dev/null | sed -E 's/^v?([0-9.]+).*/\1/')"
  if version_ge "$v" 3.8.0; then ok "helm ${v}"; else bad "helm ${v} < 3.8 (OCI support)"; fi
fi
for c in cosign trivy syft oras; do
  if command -v "$c" >/dev/null 2>&1; then ok "${c}: $(command -v "$c")"
  else soft "${c} not installed: make tools (needed for signing, scans, solution bundles)"; fi
done
if [[ -f "$LOCK_FILE" ]] && [[ -n "$arch" ]]; then
  missing="$(lock_q '[.binaries | to_entries[] | select((.value.groups | index("tools")) and (.value.platforms | has($p) | not)) | .key] | join(" ")' --arg p "${os}/${arch}")"
  [[ -z "$missing" ]] && ok "versions.lock.yaml has ${os}/${arch} builds of every tool" \
    || soft "no ${os}/${arch} build locked for: ${missing}"
fi

if [[ "$CLUSTER_MODE" == "podman" ]]; then
  section "container runtime (${runtime})"
  if [[ "$runtime" == "podman-machine" ]]; then
    m="${PODMAN_MACHINE:-}"
    if ! command -v podman >/dev/null 2>&1; then bad "podman not installed (brew install podman)"
    else
      v="$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)"
      version_ge "${v:-0}" 5.0.0 && ok "podman client ${v}" || soft "podman client ${v:-?}: 5.x is the tested baseline for podman machine"
      # shellcheck disable=SC2086
      if ! info="$(podman machine inspect ${m} 2>/dev/null)" || [[ "$(jq 'length' <<<"$info")" == "0" ]]; then
        bad "no podman machine${m:+ ${m}}: make machine-init"
      else
        state="$(jq -r '.[0].State // "?"' <<<"$info")"
        rootful="$(jq -r '.[0].Rootful // false' <<<"$info")"
        cpus="$(jq -r '.[0].Resources.CPUs // 0' <<<"$info")"
        mem="$(jq -r '.[0].Resources.Memory // 0' <<<"$info")"
        disk="$(jq -r '.[0].Resources.DiskSize // 0' <<<"$info")"
        [[ "$state" == "running" ]] && ok "machine $(jq -r '.[0].Name' <<<"$info") is running" || bad "machine state: ${state} (podman machine start)"
        [[ "$rootful" == "true" ]] && ok "machine is rootful" || bad "machine is rootless: podman machine stop; podman machine set --rootful; podman machine start"
        (( cpus >= 4 )) && ok "machine CPUs: ${cpus}" || soft "machine CPUs: ${cpus} (4+ recommended; podman machine set --cpus 6)"
        (( mem >= 14336 )) && ok "machine memory: ${mem} MiB" || soft "machine memory: ${mem} MiB (16384 recommended; podman machine set --memory 16384)"
        (( disk >= 60 )) && ok "machine disk: ${disk} GB" || soft "machine disk: ${disk} GB (80+ recommended; podman machine set --disk-size 100)"
        if [[ "$state" == "running" ]]; then
          rawarch="$(podman info --format '{{.Host.Arch}}' 2>/dev/null || true)"
          if a="$( (arch_or_die "$rawarch" "podman machine") 2>&1)"; then ok "cluster nodes will be linux/${a}"; else bad "$a"; fi
          rl="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
          [[ "$rl" == "false" ]] && ok "default podman connection is rootful" \
            || bad "default podman connection is rootless: podman system connection default $(jq -r '.[0].Name' <<<"$info")-root"
          cg="$(podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || true)"
          [[ "$cg" == "v2" ]] && ok "machine cgroups ${cg}" || soft "machine cgroups ${cg:-?} (v2 expected)"
        fi
      fi
    fi
    mem_host=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    (( mem_host >= 24 )) && ok "Mac memory: ${mem_host} GB" || soft "Mac memory: ${mem_host} GB (24 GB+ recommended: the machine needs 16 GB)"
    free_gb=$(( $(df -Pk "$HOME" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
    (( free_gb >= 100 )) && ok "free disk for the machine image: ${free_gb} GB" || soft "free disk: ${free_gb} GB (100 GB+ recommended)"
    if [[ -f "${STATE_DIR}/pki/registry-ca.crt" ]]; then
      if "${REPO_ROOT}/scripts/cluster/macos-trust.sh" "$ENV" check >/dev/null 2>&1; then ok "dev CAs trusted in the System keychain"
      else soft "dev CAs not trusted by macOS yet: make macos-trust ENV=${ENV}"; fi
    fi
  else
    [[ "$(id -u)" == "0" ]] && ok "running as root" || bad "the dev scripts need root (sudo -i): privileged k3s container, ports 80/443, sysctl, /etc/hosts"
    if command -v podman >/dev/null 2>&1; then
      rl="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
      [[ "$rl" == "false" ]] && ok "podman runs rootful" || bad "podman is rootless (run as root)"
      rawarch="$(podman info --format '{{.Host.Arch}}' 2>/dev/null || uname -m)"
      if a="$( (arch_or_die "$rawarch" "podman host") 2>&1)"; then ok "cluster nodes will be linux/${a}"; else bad "$a"; fi
    fi
    if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]]; then ok "cgroup v2"
    else soft "cgroup v1 host: kubelet runs with fail-cgroupv1=false (dev only)"; fi
    cpus="$(getconf _NPROCESSORS_ONLN)"
    (( cpus >= 4 )) && ok "CPUs: ${cpus}" || soft "CPUs: ${cpus} (4+ recommended)"
    mem=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
    (( mem >= 15 )) && ok "memory: ${mem} GB" || soft "memory: ${mem} GB (16 GB recommended)"
    gr="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo /var/lib/containers)"
    free_gb=$(( $(df -Pk "$gr" 2>/dev/null | awk 'NR==2 {print $4}') / 1024 / 1024 ))
    if (( free_gb >= 40 )); then ok "free disk (${gr}): ${free_gb} GB"
    elif (( free_gb >= 2 )); then soft "free disk (${gr}): ${free_gb} GB (40 GB recommended for a fresh mirror; prune images)"
    else bad "free disk (${gr}): ${free_gb} GB: the dev node evicts pods below 1 GiB (DiskPressure)"; fi
  fi

  section "ports (${DEV_PUBLISH_ADDR:-127.0.0.1})"
  NODE="${CLUSTER_NAME}-server-0"; ZOT="${CLUSTER_NAME}-zot"
  ours=""
  for c in "$NODE" "$ZOT"; do
    if podman container exists "$c" 2>/dev/null; then ours+=" $(podman port "$c" 2>/dev/null | sed -E 's/.*:([0-9]+)$/\1/' | tr '\n' ' ')"; fi
  done
  for p in "$DEV_HTTPS_PORT" "$DEV_HTTP_PORT" "$DEV_API_PORT" "$DEV_REGISTRY_PORT"; do
    if [[ " $ours " == *" ${p} "* ]]; then ok "port ${p}: published by the ${CLUSTER_NAME} containers"
    elif port_listening 127.0.0.1 "$p"; then
      if [[ "$p" == 5000 && "$(uname -s)" == Darwin ]]; then
        bad "port 5000 is used by AirPlay Receiver: turn it off (System Settings > General > AirDrop & Handoff) or keep the macOS default REGISTRY_HOST port 5050"
      else bad "port ${p} is used by another program (stop it; moving the dev ports breaks the Keycloak redirects)"; fi
    else ok "port ${p} is free"; fi
  done

  if [[ "$runtime" == "podman-machine" ]]; then
    if "${REPO_ROOT}/scripts/cluster/macos-ports.sh" "$ENV" check >/dev/null 2>&1; then
      ok "pf redirect active: 127.0.0.1:443 -> ${DEV_HTTPS_PORT}, :80 -> ${DEV_HTTP_PORT}"
    else
      bad "the pf redirect is not active (the public URLs are on 443): make macos-ports ENV=${ENV} (sudo)"
    fi
  fi

  section "names and trust"
  reg="${REGISTRY_HOST%%:*}"
  if name_resolves "$reg"; then ok "${reg} resolves"
  elif [[ "${DEV_MANAGE_ETC_HOSTS:-0}" == "1" ]]; then ok "${reg}: /etc/hosts entry is added by make cluster-up"
  else soft "${reg} does not resolve: DEV_MANAGE_ETC_HOSTS=1 make cluster-up (sudo on macOS), or add: $("${REPO_ROOT}/scripts/cluster/etc-hosts.sh" "$ENV" print | sed -n 2p)"; fi
fi

if [[ -f "$LOCK_FILE" ]]; then
  section "versions.lock.yaml"
  if [[ -n "${CLUSTER_ARCH:-}" ]]; then
    n="$(lock_q '[.images[] | select((.digests // {}) | has($a) | not)] | length' --arg a "$CLUSTER_ARCH")"
    (( n == 0 )) && ok "every image has a linux/${CLUSTER_ARCH} digest" || bad "${n} image(s) without linux/${CLUSTER_ARCH} (make lock; docs/versions.md)"
    n="$(lock_q '[.binaries[] | select((.groups | index("cluster")) and (.platforms | has($p) or has("any") | not))] | length' --arg p "linux/${CLUSTER_ARCH}")"
    (( n == 0 )) && ok "k3s binaries locked for linux/${CLUSTER_ARCH}" || bad "${n} cluster binaries without linux/${CLUSTER_ARCH}"
  else
    soft "cluster architecture unknown (podman machine not running?)"
  fi
fi

if [[ "${DOCTOR_NETWORK:-0}" == "1" ]]; then
  section "internet (make lock / airgap-mirror)"
  for u in https://github.com https://registry-1.docker.io/v2/ https://ghcr.io/v2/ https://quay.io/v2/ https://get.helm.sh https://registry.opentofu.org; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u" || true)"
    [[ "$code" =~ ^[234] ]] && ok "${u} (${code})" || soft "${u} not reachable (${code:-no answer}); proxy/firewall?"
  done
fi

printf '\n' >&2
if (( fails > 0 )); then err "doctor: ${fails} problem(s), ${warns} warning(s)"; exit 1; fi
log "doctor: OK (${warns} warning(s))"
