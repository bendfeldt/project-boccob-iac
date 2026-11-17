output "catalog_uri" {
  description = "Iceberg REST endpoint of Polaris."
  value       = module.polaris.catalog_uri
}

output "principal_kv_paths" {
  description = "Polaris principal => OpenBao KV path of its credentials."
  value       = module.polaris.principal_kv_paths
}
