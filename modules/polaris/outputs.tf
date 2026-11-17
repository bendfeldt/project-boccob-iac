output "service" {
  description = "Service name."
  value       = local.name
  depends_on  = [helm_release.this]
}

output "host" {
  description = "In-cluster host name (matches the server certificate)."
  value       = local.host
}

output "catalog_uri" {
  description = "Iceberg REST endpoint."
  value       = "https://${local.host}:8181/api/catalog"
  depends_on  = [kubernetes_job_v1.provision]
}

output "root_kv_path" {
  description = "OpenBao KV path of the root principal credentials (client-id, client-secret, realm)."
  value       = module.root_credentials.kv_path
}

output "principal_kv_paths" {
  description = "Principal name => OpenBao KV path of its credentials (available once provisioning has completed)."
  value       = { for name, _ in var.principals : name => "${local.principals_kv_prefix}/${name}" }
  depends_on  = [kubernetes_job_v1.provision]
}

output "management_port" {
  description = "Plain-HTTP management port (health, Prometheus metrics at /q/metrics)."
  value       = 8182
}
