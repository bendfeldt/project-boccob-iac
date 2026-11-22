# 12-foundation-services

- namespace `database` (NetworkPolicies, PostgreSQL backup credentials and CA
  Secret for every CloudNativePG cluster)
- namespace `storage` + RustFS, contract buckets (versioned), S3 users
- ingress hosts `s3.`, `s3-console.`, `openbao.<base_domain>`
  with certificates from the OpenBao PKI and verified TLS to the backends

This stack is where the next work packages register what they need from the
foundation (all through variables in `environments/<env>/12-foundation-services.tfvars`):
`buckets`, `s3_users`, `postgres_client_namespaces`, `s3_client_namespaces`,
`metrics_namespaces`. OIDC clients and Keycloak: stack `13-identity`.
