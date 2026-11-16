output "endpoint" {
  description = "In-cluster S3 endpoint (HTTPS, certificate from the platform PKI)."
  value       = local.endpoint
}

output "service" {
  description = "Service name (ports: 9000 S3 API, 9001 console)."
  value       = local.service
}

output "region" {
  description = "S3 region."
  value       = var.region
}

output "root_kv_path" {
  description = "OpenBao KV v2 path of the root credentials (RUSTFS_ACCESS_KEY / RUSTFS_SECRET_KEY)."
  value       = module.root_credentials.kv_path
}

output "user_kv_paths" {
  description = "Map user => OpenBao KV v2 path (properties access-key, secret-key)."
  value       = { for name, m in module.user_credentials : name => m.kv_path }
}

output "buckets" {
  description = "Provisioned buckets."
  value       = keys(var.buckets)
  depends_on  = [kubernetes_job_v1.provision]
}
