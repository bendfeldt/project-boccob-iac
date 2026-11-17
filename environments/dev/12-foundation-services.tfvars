# dev sizing: single instances, small volumes
postgres_storage_size    = "1Gi"
rustfs_data_storage_size = "5Gi"

# --- registered by the data plane (stacks 20-catalog, 21-query, 22-orchestration) ---
s3_users = {
  # Trino: reads and writes Iceberg data files of all layers
  "lakehouse-query" = { read_write_buckets = ["lakehouse-raw", "lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"] }
  # Dagster run pods (dlt landing, erasure, retention): rw raw, read-only on the other layers (erasure storage scan)
  "lakehouse-orchestration" = {
    read_write_buckets = ["lakehouse-raw"]
    read_only_buckets  = ["lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"]
  }
}
oidc_clients = {
  # service account that reads group memberships for the Trino file group provider
  "trino-group-sync" = {
    name                         = "Trino group sync"
    standard_flow                = false
    service_account              = true
    service_account_client_roles = { "realm-management" = ["view-users", "query-groups"] }
  }
  # dev only: password grant on the trino client so that scripts/verify.sh and
  # scripts/dev/e2e.sh can obtain user tokens without a browser
  trino = {
    name                 = "Trino"
    redirect_uris        = ["https://trino.dev.lakehouse.internal/oauth2/callback", "https://trino.dev.lakehouse.internal/ui/logout/logout.html"]
    direct_access_grants = true
  }
}
