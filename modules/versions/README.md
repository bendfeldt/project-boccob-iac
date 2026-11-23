# versions

Reads `versions.lock.yaml` (repo root) and exposes digest-pinned image
references and chart coordinates **pointing at the Zot mirror**.

```hcl
module "versions" {
  source        = "../../modules/versions"
  registry_host = var.registry_host
  arch          = var.cluster_arch   # amd64 (x64) | arm64; default amd64
}

image   = module.versions.images["openbao"].ref          # registry/quay.io/openbao/openbao:2.7.3@sha256:...
chart   = module.versions.charts["openbao"]              # { repository, name, version }
```

Stacks get this module for free through `stacks/_shared/common.tf`
(`module.versions`). Reusable modules never read the lock themselves: they
take `image` / `chart` objects as input variables.

## Architectures

`versions.lock.yaml` holds one manifest digest per platform for every image
(`digests.amd64`, `digests.arm64`) plus the upstream `index_digest`. `arch`
selects the digest of the cluster's node architecture, so a pod spec always
references exactly the single-platform manifest that was mirrored into Zot
(`scripts/airgap/mirror.sh` copies per-arch manifests, not whole indexes:
see docs/versions.md, "Mirroring per architecture"). `scripts/tofu.sh` sets
`TF_VAR_cluster_arch` from `CLUSTER_ARCH` (detected for dev, set in
`environments/<env>/env.sh` for test/prod). Images without a build for `arch`
are left out of `images` and listed in the `missing_images` output.
