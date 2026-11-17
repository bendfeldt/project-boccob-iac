# tls-certificate

cert-manager `Certificate` from ClusterIssuer `openbao-pki` for an in-cluster
server (`<svc>.<namespace>.svc`).

```hcl
module "tls" {
  source    = "../tls-certificate"
  name      = "polaris-tls"
  namespace = var.namespace
  dns_names = ["polaris.catalog.svc", "polaris.catalog.svc.cluster.local"]
}
```
