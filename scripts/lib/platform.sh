#!/usr/bin/env bash
# Platform detection and portable wrappers (Linux x64/arm64, macOS on Apple Silicon).
# Sourced by scripts/lib/common.sh; needs log/warn/die from there.
#
#   Supported cluster platforms : linux/amd64 (x64, x86_64) and linux/arm64 (aarch64)
#   Supported operator machines : Linux amd64/arm64, macOS arm64 (Apple Silicon)
#
# CLUSTER_RUNTIME (dev, CLUSTER_MODE=podman) says where the containers run:
#   native          podman runs on this Linux machine (the tested path)
#   podman-machine  podman runs inside a ROOTFUL `podman machine` VM (macOS);
#                   the scripts run on the Mac and reach the VM through the podman
#                   remote connection (containers, images) and `podman machine ssh`
#                   (kernel settings, files that are bind-mounted into containers)
# Default: macOS -> podman-machine, Linux -> native.
# shellcheck shell=bash

export SUPPORTED_ARCHES="amd64 arm64"

# normalize_arch <name>: uname -m / podman / OCI spelling -> amd64|arm64 (exit 1 otherwise)
normalize_arch() {
  case "${1:-}" in
    x86_64|amd64|x64) echo amd64 ;;
    aarch64|arm64|arm64/v8|aarch64/v8) echo arm64 ;;
    *) return 1 ;;
  esac
}

# arch_or_die <raw name> <what> : normalized arch, or a clear error for unsupported ones
arch_or_die() {
  local raw="$1" what="$2" a
  if a="$(normalize_arch "$raw")"; then echo "$a"; return 0; fi
  case "$raw" in
    i?86|x86|386)
      die "${what}: 32-bit x86 (${raw}) is not supported. Supported: x64 (x86_64/amd64) and arm64 (aarch64)." ;;
    arm|armv*|arm/v*)
      die "${what}: 32-bit ARM (${raw}) is not supported. Supported: x64 (x86_64/amd64) and arm64 (aarch64)." ;;
    "")
      die "${what}: could not determine the CPU architecture" ;;
    *)
      die "${what}: CPU architecture '${raw}' is not supported. Supported: x64 (x86_64/amd64) and arm64 (aarch64)." ;;
  esac
}

# host_os -> linux|darwin
host_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) die "operating system '$(uname -s)' is not supported (Linux or macOS)" ;;
  esac
}

# host_arch -> amd64|arm64 of THIS machine (where the scripts run)
host_arch() {
  local m; m="$(uname -m)"
  if [[ "$(uname -s)" == "Darwin" && "$m" == "x86_64" ]] \
     && [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]]; then
    # an x86_64 shell under Rosetta 2 on Apple Silicon
    die "this shell runs under Rosetta 2 (x86_64 emulation) on an Apple Silicon Mac; use a native arm64 shell (e.g. /opt/homebrew/bin/bash)"
  fi
  arch_or_die "$m" "this machine"
}

# host_platform -> <os>/<arch> of this machine, e.g. linux/amd64, darwin/arm64
host_platform() { printf '%s/%s' "$(host_os)" "$(host_arch)"; }

# cluster_runtime -> native|podman-machine (see header)
cluster_runtime() {
  local r="${CLUSTER_RUNTIME:-}"
  if [[ -z "$r" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then r="podman-machine"; else r="native"; fi
  fi
  case "$r" in
    native|podman-machine) echo "$r" ;;
    *) die "CLUSTER_RUNTIME=${r}: must be native or podman-machine" ;;
  esac
}

# podman_machine_args -> optional machine name for `podman machine ...`
podman_machine_args() { [[ -n "${PODMAN_MACHINE:-}" ]] && printf '%s' "$PODMAN_MACHINE"; return 0; }

# container_host_exec <cmd...> : run a command as root on the machine that runs the
# containers (this Linux host, or the podman machine VM through `podman machine ssh`).
# Arguments are joined into one shell command line in the VM: quote with care.
container_host_exec() {
  if [[ "$(cluster_runtime)" == "podman-machine" ]]; then
    local m; m="$(podman_machine_args)"
    # shellcheck disable=SC2086 # empty machine name -> default machine
    podman machine ssh ${m} "sudo sh -c $(printf '%q' "$*")"
  else
    sh -c "$*"
  fi
}

# container_host_sync_dir <local dir> <dir on the container host>: make a local
# directory available for bind mounts. Native: nothing to do (prints the local dir).
# podman-machine: copies it into the VM (root-owned, so containers that drop all
# capabilities can still read 0600 files) and prints the VM path. Files are not
# taken from the /Users share: its ownership and SELinux labels do not suit
# bind mounts into rootful containers.
container_host_sync_dir() {
  local src="$1" dst="$2"
  if [[ "$(cluster_runtime)" != "podman-machine" ]]; then printf '%s' "$src"; return 0; fi
  local m; m="$(podman_machine_args)"
  # shellcheck disable=SC2086
  tar_c_root "$src" | podman machine ssh ${m} \
    "sudo sh -c $(printf '%q' "rm -rf '${dst}.new' && mkdir -p '${dst}.new' && tar -xf - -C '${dst}.new' && rm -rf '${dst}' && mv '${dst}.new' '${dst}' && chown -R 0:0 '${dst}'")" \
    || die "cannot copy ${src} into the podman machine (${dst})"
  printf '%s' "$dst"
}

# container_host_write_file <path> [mode] : stdin -> file on the container host (as root)
container_host_write_file() {
  local path="$1" mode="${2:-0644}"
  if [[ "$(cluster_runtime)" == "podman-machine" ]]; then
    local m; m="$(podman_machine_args)"
    # shellcheck disable=SC2086
    podman machine ssh ${m} "sudo sh -c $(printf '%q' "mkdir -p \"\$(dirname '${path}')\" && cat > '${path}.tmp' && chmod ${mode} '${path}.tmp' && mv '${path}.tmp' '${path}'")"
  else
    mkdir -p "$(dirname "$path")"
    cat > "${path}.tmp" && chmod "$mode" "${path}.tmp" && mv "${path}.tmp" "$path"
  fi
}

# container_host_hosts_block <name> <line|""> : maintain a marked block in the
# container host's /etc/hosts (podman machine VM: podman inside it must resolve
# the registry name to its own published port). Empty line removes the block.
container_host_hosts_block() {
  local name="$1" line="$2" b e f="${CONTAINER_HOST_HOSTS_FILE:-/etc/hosts}" script
  b="# >>> ${name} (managed by project-boccob-iac)"; e="# <<< ${name}"
  script="awk -v b='${b}' -v e='${e}' '\$0==b{s=1} !s{print} \$0==e{s=0}' ${f} > ${f}.boccob"
  if [[ -n "$line" ]]; then
    script+=" && printf '%s\\n%s\\n%s\\n' '${b}' '${line}' '${e}' >> ${f}.boccob"
  fi
  script+=" && cat ${f}.boccob > ${f} && rm -f ${f}.boccob"
  container_host_exec "$script"
}

# require_rootful_podman : podman must run containers as root (privileged k3s node,
# ports 80/443, netfilter). Native: run the scripts as root. Machine: rootful VM.
require_rootful_podman() {
  local rootless
  rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" \
    || die "podman is not reachable$([[ "$(cluster_runtime)" == podman-machine ]] && echo ': start the machine (podman machine start) or create it (make machine-init)')"
  if [[ "$rootless" != "false" ]]; then
    if [[ "$(cluster_runtime)" == "podman-machine" ]]; then
      die "the podman machine is rootless; the dev cluster needs a rootful machine: podman machine stop; podman machine set --rootful; podman machine start (or make machine-init)"
    fi
    die "rootless podman is not supported: run the dev scripts as root (sudo -i)"
  fi
}

# name_resolves <hostname> : true when this machine resolves the name (portable:
# curl exit code 6 = could not resolve host)
name_resolves() {
  local rc=0
  curl -s -o /dev/null --noproxy '*' --connect-timeout 2 --max-time 3 "http://${1}:9/" || rc=$?
  [[ $rc -ne 6 ]]
}

# port_listening <addr> <port> : true when something accepts TCP connections there
port_listening() { (exec 3<>"/dev/tcp/${1}/${2}") 2>/dev/null; }

# tar_c_root <dir> : tar of a directory's content on stdout, entries owned by root (GNU or BSD tar)
tar_c_root() {
  if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar -C "$1" --owner=0 --group=0 --numeric-owner -cf - .
  else
    tar -C "$1" --uid 0 --gid 0 -cf - .
  fi
}

# --- portable wrappers (GNU coreutils vs. macOS/BSD) ---------------------------------
# sha256 of stdin or files, "<sum>  <name>" lines like GNU sha256sum
sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"
  else die "neither sha256sum nor shasum found"; fi
}
sha256_of() { sha256_stream "$1" | awk '{print $1}'; }

# sha256_manifest : SHA256SUMS of every file below the current directory (stable order)
sha256_manifest() {
  local f
  find . -type f ! -name 'SHA256SUMS*' | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256_of "$f")" "$f"
  done
}

# sha256_check <SHA256SUMS file> : verify "<sum>  <path>" lines relative to the
# current directory; prints mismatches, non-zero exit on any failure
sha256_check() {
  local sums="$1" want path got rc=0
  while read -r want path; do
    [[ -n "$want" ]] || continue
    path="${path#\*}"
    if [[ ! -f "$path" ]]; then echo "${path}: MISSING" >&2; rc=1; continue; fi
    got="$(sha256_of "$path")"
    [[ "$got" == "$want" ]] || { echo "${path}: FAILED" >&2; rc=1; }
  done < "$sums"
  return $rc
}

# base64 without line wrapping (GNU wraps at 76 unless -w0; BSD has no -w)
b64_nowrap() { base64 | tr -d '\n'; }

# file_size <file> -> bytes
file_size() { wc -c < "$1" | tr -d ' '; }
