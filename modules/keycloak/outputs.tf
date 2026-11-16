output "service" {
  description = "Service name (ports: 8443 https, 9000 management/metrics)."
  value       = kubernetes_service_v1.this.metadata[0].name
}

output "internal_host" {
  description = "In-cluster service host; matches the pod certificate."
  value       = local.internal_host
}

output "issuer" {
  description = "OIDC issuer URL of the realm (same inside and outside the cluster)."
  value       = local.issuer
}

output "realm" {
  description = "Managed realm."
  value       = var.realm
  depends_on  = [kubernetes_job_v1.realm_config]
}

output "client_kv_paths" {
  description = "Map client id => OpenBao KV v2 path (properties client-id, client-secret, issuer)."
  value       = { for id, m in module.client_credentials : id => m.kv_path }
}

output "admin_kv_path" {
  description = "OpenBao KV v2 path of the bootstrap admin credentials."
  value       = module.admin_credentials.kv_path
}
