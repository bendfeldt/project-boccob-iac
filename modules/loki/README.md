# loki

Loki single binary on S3 (RustFS), HTTPS (platform PKI), multi-tenant
(`auth_enabled`): tenants and retention per tenant through `tenants`
(runtime overrides), compactor retention enabled. Loki has no authentication of
its own: callers are limited by NetworkPolicy, and Grafana scopes tenants per
data source. S3 credentials come from a Secret (`access_key_id`,
`secret_access_key`) as environment variables (`-config.expand-env`).
HA: more replicas use replication factor 2; a SimpleScalable deployment is not
implemented. See stack 30-observability for usage.
