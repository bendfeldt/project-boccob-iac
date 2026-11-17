# 21-query

Trino and OPA in namespace `query` (modules/trino, modules/opa).

```
make deploy ENV=<env> STACK=21-query
```

Inputs per environment (`environments/<env>/21-query.tfvars`): `opa_bundle_ref`
(digest-pinned bundle published by the solution repository), `registry_cidrs`.
Secrets: `kv/query/trino/shared-secret`, `kv/query/trino/service-accounts/<name>`.
Public endpoint: `https://trino.<base_domain>` (OAuth2 for people, basic auth
for service accounts). Design notes: docs/data-plane.md.
