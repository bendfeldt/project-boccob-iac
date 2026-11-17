output "service" {
  description = "Coordinator Service name (ports: 8443 https for clients, 8080 http for cluster-internal traffic)."
  value       = local.name
  depends_on  = [helm_release.this]
}

output "host" {
  description = "In-cluster host name of the coordinator (matches the server certificate)."
  value       = local.host
}

output "https_port" {
  description = "HTTPS port for clients."
  value       = 8443
}

output "service_account_kv_paths" {
  description = "Service account name => OpenBao KV path (username, password)."
  value       = { for name, _ in var.service_accounts : name => "${var.kv_prefix}/service-accounts/${name}" }
  depends_on  = [helm_release.this]
}
