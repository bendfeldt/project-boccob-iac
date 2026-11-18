# 13-identity

- namespace `identity` + Keycloak, realm `lakehouse`, roles/groups, OIDC
  clients (trino, polaris, dagster, grafana, grafana-audit, openbao + `oidc_clients`)
- PostgreSQL cluster `keycloak-db` in namespace `database` (owned by stack 12;
  backup credentials `platform-backup-s3` and CA Secret `platform-ca` there)
- ingress host `keycloak.<base_domain>`

Split out of `12-foundation-services` on 2026-11-18 because that stack's state
Secret reached the 1 MiB limit; the resources were moved with their state
(`tofu state mv`), nothing was recreated (docs/architecture.md, "OpenTofu state").

Variables per environment: `environments/<env>/13-identity.tfvars`
(`oidc_clients`, `keycloak_replicas`, `keycloak_resources`,
`keycloak_client_namespaces`, `postgres_*` of keycloak-db). Must run after
stack 12 (lexical order of `make deploy`).
