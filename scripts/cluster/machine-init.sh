#!/usr/bin/env bash
# macOS (and other podman-machine hosts): create or adjust the ROOTFUL podman
# machine the dev cluster runs in, then start it.     make machine-init
#
#   PODMAN_MACHINE   machine name (default: podman-machine-default)
#   MACHINE_CPUS     vCPUs            (default 6; minimum 4)
#   MACHINE_MEMORY   memory in MiB    (default 16384; minimum 12288)
#   MACHINE_DISK     disk in GB       (default 100; minimum 60; can only grow)
#
# Rootful: the k3s node is a --privileged container that publishes ports 80/443
# and needs netfilter and cgroup access, which a rootless machine cannot give.
# The machine runs Fedora CoreOS with the Mac's architecture (arm64 on Apple
# Silicon), so the cluster runs linux/arm64 images natively (no emulation).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_cmd podman jq

name="${PODMAN_MACHINE:-podman-machine-default}"
cpus="${MACHINE_CPUS:-6}"
mem="${MACHINE_MEMORY:-16384}"
disk="${MACHINE_DISK:-100}"
[[ "$cpus" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ && "$disk" =~ ^[0-9]+$ ]] || die "MACHINE_CPUS/MACHINE_MEMORY/MACHINE_DISK must be integers"
(( cpus >= 4 )) || die "MACHINE_CPUS=${cpus}: at least 4"
(( mem >= 12288 )) || die "MACHINE_MEMORY=${mem} MiB: at least 12288 (16384 recommended)"
(( disk >= 60 )) || die "MACHINE_DISK=${disk} GB: at least 60 (100 recommended)"

os="$(host_os)"; arch="$(host_arch)"
[[ "$os" == "darwin" ]] || warn "podman machine on ${os}: untested (on Linux the dev scripts run podman natively as root)"
log "host ${os}/${arch}: the machine and the cluster will be linux/${arch}"
if [[ "$os" == "darwin" ]]; then
  host_cpus="$(sysctl -n hw.ncpu)"; host_mem=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
  (( cpus <= host_cpus )) || die "MACHINE_CPUS=${cpus} > ${host_cpus} CPUs of this Mac"
  (( mem + 4096 <= host_mem )) || die "MACHINE_MEMORY=${mem} MiB leaves less than 4 GB for macOS (this Mac has ${host_mem} MiB)"
  free_gb=$(( $(df -Pk "$HOME" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  (( free_gb > disk / 2 )) || warn "only ${free_gb} GB free on this Mac; the machine disk grows up to ${disk} GB"
fi

if ! podman machine inspect "$name" >/dev/null 2>&1; then
  step "podman machine init ${name} (rootful, ${cpus} CPU, ${mem} MiB, ${disk} GB)"
  podman machine init --rootful --cpus "$cpus" --memory "$mem" --disk-size "$disk" "$name"
else
  info="$(podman machine inspect "$name")"
  state="$(jq -r '.[0].State' <<<"$info")"
  have_cpus="$(jq -r '.[0].Resources.CPUs' <<<"$info")"
  have_mem="$(jq -r '.[0].Resources.Memory' <<<"$info")"
  have_disk="$(jq -r '.[0].Resources.DiskSize' <<<"$info")"
  rootful="$(jq -r '.[0].Rootful' <<<"$info")"
  set_args=()
  [[ "$rootful" == "true" ]] || set_args+=(--rootful)
  (( have_cpus == cpus )) || set_args+=(--cpus "$cpus")
  (( have_mem == mem )) || set_args+=(--memory "$mem")
  if (( have_disk < disk )); then set_args+=(--disk-size "$disk")
  elif (( have_disk > disk )); then warn "machine disk is ${have_disk} GB (cannot shrink to ${disk})"; fi
  if [[ ${#set_args[@]} -gt 0 ]]; then
    step "podman machine set ${set_args[*]} ${name}"
    if [[ "$state" == "running" ]]; then podman machine stop "$name"; state=stopped; fi
    podman machine set "${set_args[@]}" "$name"
  else
    log "machine ${name} already rootful with ${cpus} CPU, ${mem} MiB, ${have_disk} GB"
  fi
fi

if [[ "$(podman machine inspect "$name" | jq -r '.[0].State')" != "running" ]]; then
  step "podman machine start ${name}"
  podman machine start "$name"
fi
# a rootful machine registers "<name>-root"; the scripts use the default connection
if podman system connection list --format '{{.Name}}' 2>/dev/null | grep -qx "${name}-root"; then
  podman system connection default "${name}-root"
fi
[[ "$(podman info --format '{{.Host.Security.Rootless}}')" == "false" ]] \
  || die "the default podman connection is still rootless (podman system connection list)"
log "machine ${name} ready: linux/$(arch_or_die "$(podman info --format '{{.Host.Arch}}')" "podman machine"), rootful"
log "next: make doctor ENV=dev, then make cluster-up ENV=dev (docs/getting-started.md, macOS section)"
