output "trino_url" {
  description = "In-cluster Trino endpoint."
  value       = "https://${module.trino.host}:${module.trino.https_port}"
}

output "service_account_kv_paths" {
  description = "Trino service account => OpenBao KV path (username, password)."
  value       = module.trino.service_account_kv_paths
}

output "opa_url" {
  description = "OPA endpoint used by Trino."
  value       = module.opa.url
}
