# oauth2-proxy

OIDC login (Keycloak, PKCE) in front of an application that has no
authentication of its own (Dagster OSS). Only members of `allowed_groups`
(token claim `groups`) get through; the cookie secret is generated in-cluster
and stored in OpenBao. HTTPS on 8443 (certificate from `openbao-pki`) for the
ingress controller; the upstream is called inside the namespace.

```hcl
module "dagster_auth" {
  source         = "../oauth2-proxy"
  name           = "dagster-auth"
  namespace      = module.ns_orchestration.name
  image          = module.versions.images["oauth2-proxy"].ref
  public_host    = "dagster.${var.base_domain}"
  upstream       = "http://dagster-webserver.orchestration.svc:80"
  oidc           = { issuer = local.platform.oidc_issuer, client_id = "dagster", client_secret_kv_path = "identity/oidc-clients/dagster" }
  allowed_groups = ["platform-admin", "data-engineer"]
  kv_prefix      = "orchestration/dagster-auth"
}
```
