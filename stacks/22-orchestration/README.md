# 22-orchestration

Dagster in namespace `orchestration` (modules/dagster, modules/oauth2-proxy):
webserver + daemon + the solution's code location, K8sRunLauncher (run pods
with the code location's image, environment and volumes), PostgreSQL
`dagster-db`, UI at `https://dagster.<base_domain>` behind oauth2-proxy
(Keycloak groups `dagster_ui_groups`).

```
make deploy ENV=<env> STACK=22-orchestration
```

Input per environment (`environments/<env>/22-orchestration.tfvars`):
`dagster_code_location_image` (digest-pinned, from the solution repository).
Secrets (OpenBao): `kv/orchestration/pseudonym-pepper` (created once, never
overwritten: back it up), `kv/orchestration/dagster-auth/cookie-secret`; the
code location reads S3, Polaris and Trino credentials from the paths of
stacks 12/20/21. Design notes: docs/data-plane.md.
