# kyverno

Kyverno Helm release with images from Zot (`registry` + `repository` +
`tag@digest`), admission + reports controller (background controller
optional, cleanup controller off), CRDs, PolicyExceptions only from the Kyverno
namespace, JSON logs, `kube-system` excluded from the webhooks, the Zot CA as
`global.caCertificates` (signature lookups). The webhook/readiness-checker
hooks are disabled because they need extra upstream images. HA: 3 admission
replicas, PDBs.

```hcl
module "kyverno" {
  source          = "../../modules/kyverno"
  namespace       = module.ns_kyverno.name
  chart           = module.versions.charts["kyverno"]
  images          = { admission = module.versions.images["kyverno"], pre = module.versions.images["kyverno-pre"], background = module.versions.images["kyverno-background-controller"], reports = module.versions.images["kyverno-reports-controller"] }
  registry_ca_pem = file("~/.boccob/dev/pki/registry-ca.crt")
}
```
