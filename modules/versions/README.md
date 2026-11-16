# versions

Reads `versions.lock.yaml` (repo root) and exposes digest-pinned image
references and chart coordinates **pointing at the Zot mirror**.

```hcl
module "versions" {
  source        = "../../modules/versions"
  registry_host = var.registry_host
}

image   = module.versions.images["openbao"].ref          # registry/quay.io/openbao/openbao:2.7.2@sha256:...
chart   = module.versions.charts["openbao"]              # { repository, name, version }
```

Stacks get this module for free through `stacks/_shared/common.tf`
(`module.versions`). Reusable modules never read the lock themselves: they
take `image` / `chart` objects as input variables.
