output "oidc_issuer" {
  description = "OIDC issuer of the lakehouse realm."
  value       = module.keycloak.issuer
}

output "oidc_client_kv_paths" {
  description = "OIDC client => OpenBao KV path (client-id, client-secret, issuer)."
  value       = module.keycloak.client_kv_paths
}

output "keycloak_db_host" {
  description = "Keycloak PostgreSQL read-write host."
  value       = module.keycloak_db.host
}
