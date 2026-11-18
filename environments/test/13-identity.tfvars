postgres_instances = 3

postgres_storage_size = "10Gi"

postgres_resources = {
  requests = { cpu = "250m", memory = "1Gi" }
  limits   = { memory = "2Gi" }
}

keycloak_replicas = 2

keycloak_resources = {
  requests = { cpu = "500m", memory = "1536Mi" }
  limits   = { memory = "2Gi" }
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
