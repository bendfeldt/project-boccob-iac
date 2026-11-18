output "s3_endpoint" {
  description = "In-cluster S3 endpoint."
  value       = module.rustfs.endpoint
}

output "s3_external_url" {
  description = "S3 endpoint through the ingress."
  value       = module.ingress_s3.url
}

output "buckets" {
  description = "Provisioned buckets."
  value       = module.rustfs.buckets
}

output "s3_user_kv_paths" {
  description = "S3 user => OpenBao KV path (access-key, secret-key)."
  value       = module.rustfs.user_kv_paths
}
