output "dagster_url" {
  description = "Public Dagster UI (oauth2-proxy)."
  value       = "https://dagster.${var.base_domain}"
  depends_on  = [module.ingress_dagster]
}

output "pepper_kv_path" {
  description = "OpenBao KV path of the pseudonymisation pepper."
  value       = module.dagster.pepper_kv_path
}
