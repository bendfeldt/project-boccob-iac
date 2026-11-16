# 12-foundation-services

- namespace `database` + PostgreSQL cluster `keycloak-db` (CloudNativePG)
- namespace `storage` + RustFS, contract buckets (versioned), S3 users
- namespace `identity` + Keycloak, realm `lakehouse`, roles/groups, OIDC
  clients (trino, polaris, dagster, grafana, openbao)
- ingress hosts `keycloak.`, `s3.`, `s3-console.`, `openbao.<base_domain>`
  with certificates from the OpenBao PKI and verified TLS to the backends

This stack is where the next work packages register what they need from the
foundation (all through variables in `environments/<env>/12-foundation-services.tfvars`):
`buckets`, `s3_users`, `oidc_clients`, `postgres_client_namespaces`,
`s3_client_namespaces`, `metrics_namespaces`.
