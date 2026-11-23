# external-secret

Syncs one OpenBao KV v2 path into a Kubernetes Secret through the
namespace's own SecretStore `openbao` (created by `modules/namespace-baseline`
with `secrets_access = true`; it reads `kv/<namespace>/*` plus the paths granted
in stack 11, `namespace_secret_stores`).

```hcl
module "trino_oidc" {
  source    = "../../modules/external-secret"
  name      = "trino-oidc"
  namespace = module.ns_query.name            # secrets_access = true
  kv_path   = "identity/oidc-clients/trino"   # properties: client-id, client-secret
}
```

With `template` the Secret can be reshaped (connection strings, config files).
