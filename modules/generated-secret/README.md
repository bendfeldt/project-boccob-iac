# generated-secret

Random credentials without any value in git, tfvars or OpenTofu state:

```
Password generator ──> ExternalSecret (CreatedOnce) ──> K8s Secret ──> PushSecret ──> OpenBao kv/<kv_path>
```

```hcl
module "polaris_bootstrap" {
  source    = "../../modules/generated-secret"
  name      = "polaris-bootstrap"
  namespace = module.ns_catalog.name          # namespace baseline with secrets_access = true
  kv_path   = "catalog/polaris-bootstrap"
  keys      = ["client-secret"]
  literals  = { "client-id" = "root" }
}
```

Consumers in the same namespace mount the Secret directly; consumers in other
namespaces use `modules/external-secret` with the same `kv_path`.

Rotation: `kubectl -n <ns> delete secret <name>` (a new value is generated
and pushed; restart the consumers).


## OpenBao is the source of truth (DR)

Flow: generator -> Secret `<name>-seed` (once) -> PushSecret `IfNotExists`
(create-only) -> OpenBao `kv/<kv_path>` -> ExternalSecret -> Secret `<name>`.
After a rebuild with a restored OpenBao, the restored values win; a fresh
seed is never pushed over them. Rotation: delete the KV entry and the seed
Secret (see docs/compliance/runbooks/key-rotation.md).
