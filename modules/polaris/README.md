# polaris

Apache Polaris (official chart) with a relational-jdbc metastore.

- Root credentials are generated in-cluster and pushed to OpenBao; the
  bootstrap Job (`polaris-admin-tool bootstrap -f <file>`) creates the schema
  and the realm. Bootstrapping is idempotent.
- TLS on the API port 8181 (certificate from `openbao-pki`); the management
  port 8182 (health, `/q/metrics`) is plain HTTP for kubelet probes — keep it
  closed with NetworkPolicy except for the metrics scraper.
- Static S3 credentials for the object store (`stsUnavailable`, path style);
  the JVM trusts the platform CA through `modules/java-truststore`.
- The provisioning Job (python standard library, `files/provision.py`) creates
  catalogs, principals, principal roles, catalog roles and grants through the
  management API and stores the principal credentials Polaris generates in
  OpenBao (kubernetes auth, policy limited to `<kv_prefix>/principals/*`).
  When a principal exists but OpenBao holds no valid credentials they are rotated.
- `replicas > 1`: stateless pods behind the Service, PodDisruptionBudget and
  topology spread; the token signing key is shared through a Secret.
- `oidc != null`: authentication type `mixed` (Keycloak tokens in addition to
  Polaris principals). Rendered and validated only, not exercised.

```hcl
module "polaris" {
  source    = "../../modules/polaris"
  namespace = module.ns_catalog.name
  chart     = module.versions.charts["polaris"]
  images = {
    polaris    = module.versions.images["polaris"]
    admin_tool = module.versions.images["polaris-admin-tool"]
    postgres   = module.versions.images["postgresql"]
    python     = module.versions.images["python"]
  }
  database = { host = module.polaris_db.host, kv_path = module.polaris_db.kv_path }
  s3       = { endpoint = local.platform.s3_url, region = "us-east-1", credentials_kv_path = "storage/s3-users/lakehouse-catalog" }
  catalogs = { raw = { base_location = "s3://lakehouse-raw/iceberg", allowed_locations = ["s3://lakehouse-raw/"] } }
  principals    = { trino = { catalog_privileges = { raw = ["CATALOG_MANAGE_CONTENT"] } } }
  openbao       = { url = local.platform.openbao_url }
  ca_bundle_pem = local.platform_ca_pem
}
```

Exceptions to the pod baseline: none (non-root, read-only root filesystem).
