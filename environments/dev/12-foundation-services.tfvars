# dev sizing: single instances, small volumes
postgres_storage_size    = "1Gi"
rustfs_data_storage_size = "5Gi"

# ops (stack 32-backup), dev only: off-site copy target on the same RustFS
buckets = { "platform-backup-offsite" = {} }

# --- registered by the data plane (stacks 20-catalog, 21-query, 22-orchestration) ---
s3_users = {
  # --- ops (stack 32-backup), dev only: stand-in for the off-site S3 target ---
  "platform-offsite" = { read_write_buckets = ["platform-backup-offsite"] }
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
    # Keycloak >= 26.8 admin API: token needs scope kc-admin-api (audience check)
    optional_client_scopes = ["kc-admin-api"]
  }
  # dev only: password grant on the trino client so that scripts/verify.sh and
  # scripts/dev/e2e.sh can obtain user tokens without a browser
  trino = {
    name                 = "Trino"
    redirect_uris        = ["https://trino.dev.lakehouse.internal/oauth2/callback", "https://trino.dev.lakehouse.internal/ui/logout/logout.html"]
    direct_access_grants = true
  }
}

# ops (stack 30-observability), dev only: short WORM retention of the audit archive
audit_archive_lock = { mode = "compliance", days = 2 }
