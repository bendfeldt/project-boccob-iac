postgres_instances    = 3
postgres_storage_size = "10Gi"
postgres_resources = {
  requests = { cpu = "250m", memory = "1Gi" }
  limits   = { memory = "2Gi" }
}

rustfs_distributed       = true
rustfs_replicas          = 4
rustfs_drives_per_node   = 4
rustfs_data_storage_size = "100Gi"
rustfs_resources = {
  requests = { cpu = "1", memory = "4Gi" }
  limits   = { memory = "8Gi" }
}

keycloak_replicas = 2
keycloak_resources = {
  requests = { cpu = "500m", memory = "1536Mi" }
  limits   = { memory = "2Gi" }
}

# --- registered by the data plane (stacks 20-catalog, 21-query, 22-orchestration) ---
# Dagster step logs (S3ComputeLogManager), kept 90 days (may contain whatever a step prints)
buckets = { "dagster-compute-logs" = { versioning = false, lifecycle = { expiration_days = 90 } } }
s3_users = {
  # Trino: reads and writes Iceberg data files of all layers
  "lakehouse-query" = { read_write_buckets = ["lakehouse-raw", "lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"] }
  # Dagster run pods (dlt landing, erasure, retention): rw raw, read-only on the other layers (erasure storage scan)
  "lakehouse-orchestration" = {
    read_write_buckets = ["lakehouse-raw"]
    read_only_buckets  = ["lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"]
  }
  # Dagster erasure / retention / maintenance: remove object versions on the layer buckets
  "lakehouse-purge" = { purge_buckets = ["lakehouse-raw", "lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"] }
  # Dagster S3ComputeLogManager (webserver, daemon, run pods): own bucket only - never
  # platform-logs, whose credential also writes Loki's audit tenant and platform-audit
  "dagster-compute-logs" = { read_write_buckets = ["dagster-compute-logs"] }
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
}
