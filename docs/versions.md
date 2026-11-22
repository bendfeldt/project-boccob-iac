# Versions, the lock file and CPU architectures

Everything the platform runs or downloads is pinned in two files:

| File | Edited by | Content |
|---|---|---|
| `versions.yaml` | people | desired versions: image `source` + `tag`, chart `repo` + `version`, binary URLs, the cluster `platforms` |
| `versions.lock.yaml` | `make lock` only | what those resolve to: image digests per platform, chart sha256, binary sha256 per platform |

Scripts read the lock through `scripts/lib/common.sh` (`image_digest`, `image_zot_ref`,
`binary_platform`, ...); OpenTofu reads it through `modules/versions`. Nothing else may
name an image, chart or download.

## Supported platforms

| | amd64 (x64, x86_64) | arm64 (aarch64) |
|---|---|---|
| Cluster nodes (`linux/<arch>`) | yes: the tested path (dev on Ubuntu 24.04 x64) | yes: dev in a podman machine on Apple Silicon (**not run on real hardware yet**), arm64 servers |
| Operator machine (scripts, `make tools`) | Linux | Linux, macOS (Apple Silicon) |

The naming is always `amd64` (also written x64 or x86_64) and `arm64` (aarch64). 32-bit x86
(i386/i686), 32-bit ARM, ppc64le, s390x and riscv64 are refused with a clear message by
`scripts/lib/platform.sh` (`arch_or_die`). A cluster has exactly one architecture; mixed
amd64/arm64 node pools are not supported (k3s pulls its system images by tag, and the Zot tag
holds one architecture).

The architecture of the cluster, `CLUSTER_ARCH`, is

- dev on Linux: the architecture of the machine (`uname -m`);
- dev on macOS: the architecture of the **podman machine** (`podman info .Host.Arch`), not of
  the Mac (they are the same on Apple Silicon: arm64);
- test/prod: set in `environments/<env>/env.sh` (`CLUSTER_ARCH="${CLUSTER_ARCH:-amd64}"`).

`scripts/tofu.sh` passes it as `TF_VAR_cluster_arch`; `modules/versions` (`arch`) then returns
the digest of that architecture in every `images[...]` reference.

## Lock format

```yaml
platforms: [linux/amd64, linux/arm64]
images:
  trino:
    source: docker.io/trinodb/trino
    tag: "484"
    index_digest: sha256:2704eb...      # the upstream index (manifest list); signatures refer to it
    digests:
      amd64: sha256:...                 # linux/amd64 manifest: what an amd64 cluster runs
      arm64: sha256:...                 # linux/arm64 manifest (variant v8 or none)
    # missing_platforms: [arm64]        # only when upstream publishes no such image
    groups: [data-plane]
binaries:
  k3s:
    groups: [cluster]
    platforms:
      linux/amd64: {url: .../k3s,       file: k3s,       sha256: ..., checksums: .../sha256sum-amd64.txt}
      linux/arm64: {url: .../k3s-arm64, file: k3s-arm64, sha256: ..., checksums: .../sha256sum-arm64.txt}
  cosign:
    groups: [tools]
    platforms: {linux/amd64: ..., linux/arm64: ..., darwin/arm64: ...}
```

- `make lock` reads each upstream index with `skopeo inspect --raw` and takes the
  `linux/<arch>` entry for every platform. An image whose source and tag did not change is
  re-read **by its locked index digest**, so adding a platform never moves the digest a running
  cluster uses (tags move upstream). It refuses to change an existing amd64 digest unless run
  with `REUSE=0`.
- A platform that an image does not publish is never guessed: it is written to
  `missing_platforms`, printed at the end of `make lock`, flagged by `make lint` and
  `make doctor`, and the image is absent from `module.versions.images` for that architecture
  (a stack that needs it fails at plan time).
- Binary checksums come from the checksum file each upstream release publishes (`checksums:`).
  `k3s-install.sh` has none upstream; its sha256 is that of the download (platform `any`).
- Cluster binaries (k3s, airgap images) exist for linux/amd64 and linux/arm64; operator tools
  (cosign, trivy, syft, oras) also for darwin/arm64. `make tools` installs the build of the
  machine it runs on; `make node-bundle` packs the `linux/<CLUSTER_ARCH>` k3s files, and
  `host-install.sh` refuses a node of another architecture.

### State of the lock (resolved 2026-11-21)

All 40 images publish linux/amd64 **and** linux/arm64; there are no `missing_platforms`. Every
arm64 digest was re-checked independently (`skopeo inspect --config` of `source@digest` reports
`linux/arm64`). All binaries have upstream checksums for every listed platform; the amd64 values
equal the previous lock. Notes:

- `zot` also publishes freebsd images in its index; the lock takes the `linux` entries only.
- `kube-state-metrics` is still not listed (its blobs live on a host the build sandbox cannot
  reach, see `versions.yaml`); it publishes arm64 upstream as well.
- Being published is not the same as being tested: no arm64 cluster has run these images yet.

## Mirroring per architecture

`make airgap-mirror` / `airgap-bundle` / `airgap-load` / `airgap-check` copy and check the
images of `CLUSTER_ARCH` only: every cluster has one architecture (mixed clusters are refused)
and every environment has its own Zot.

- One single-platform manifest per architecture is copied with
  `skopeo copy --preserve-digests source@<arch digest>`: the digest in Zot is byte-identical to
  the lock, and pods reference exactly that digest.
- Zot tags: `<tag>` (k3s pulls its system images by tag).
- Bundles: `images/<key>.tar`; binaries for `linux/<CLUSTER_ARCH>` (cluster binaries and the
  tools for the air-gapped operator hosts) and this machine's own tool builds.

**Why not the whole index (manifest list)?** Referencing the index digest everywhere would make
one reference valid on both architectures, but it needs every child manifest of the index in
Zot. skopeo can copy one platform (`--multi-arch system`, which also rewrites to a
single-manifest copy), **all** platforms (`all`) or the bare index (`index-only`); it cannot copy
a selected subset (checked with skopeo 1.13 on the build machine; the `--multi-arch` modes documented for current skopeo are the same three). A
subset copy that kept the upstream index would be a "sparse" index with dangling references,
and stripping the missing entries changes the index digest. Copying `all` brings arm/v7,
ppc64le, s390x, riscv64 ... as well: 30 of the 40 images publish more than amd64 + arm64, so the
mirror and the air-gap bundle would grow 2-6x. Switching the running clusters from manifest to
index digests would also restart every workload for no functional gain. Per-arch manifest
digests keep the mirror minimal, keep the existing amd64 digests, and make the architecture an
explicit, reviewable input (`CLUSTER_ARCH`).

## Solution artefacts

The solution repository builds its code-location image for the target platform(s):
`make release-publish ENV=<env>` passes `PLATFORMS` (default `linux/<CLUSTER_ARCH>`; a single
platform gives a plain image, as before). `PLATFORMS=linux/amd64,linux/arm64` builds one image
per platform plus a manifest list, pushes the **index** and records and signs the index digest
(`dist/image/image.ref`); a foreign platform needs qemu-user-static on the build machine.
Its base images are pinned by index digest, and `make lint` there checks that every locked
Python dependency has cp313 manylinux x86_64 + aarch64 wheels.

## Changing a version

1. Edit `versions.yaml`.
2. `make lock` (needs internet), then `make lint`.
3. `make airgap-mirror ENV=dev GROUPS=<group>` and `make airgap-check ENV=dev`.
4. `make plan` / `make deploy` the stacks that use it.
