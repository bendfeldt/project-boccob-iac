# 13-identity

- namespace `identity` + Keycloak, realm `lakehouse`, roles/groups, OIDC
  clients (trino, polaris, dagster, grafana, grafana-audit, openbao + `oidc_clients`)
- PostgreSQL cluster `keycloak-db` in namespace `database` (owned by stack 12;
  backup credentials `platform-backup-s3` and CA Secret `platform-ca` there)
- ingress host `keycloak.<base_domain>`

Variables per environment: `environments/<env>/13-identity.tfvars`
(`oidc_clients`, `keycloak_replicas`, `keycloak_resources`,
`keycloak_client_namespaces`, `postgres_*` of keycloak-db). Must run after
stack 12 (lexical order of `make deploy`).
