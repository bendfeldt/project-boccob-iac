# dev sizing: single instances, small volumes
postgres_storage_size = "1Gi"

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
  # the solution's dev tests can obtain user tokens without a browser
  trino = {
    name                 = "Trino"
    redirect_uris        = ["https://trino.dev.lakehouse.internal/oauth2/callback", "https://trino.dev.lakehouse.internal/ui/logout/logout.html"]
    direct_access_grants = true
  }
}
