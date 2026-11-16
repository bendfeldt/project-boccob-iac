output "name" {
  description = "Cluster name."
  value       = var.name
  depends_on  = [kubernetes_manifest.cluster]
}

output "host" {
  description = "Read-write (primary) service FQDN; matches the server certificate."
  value       = local.host
}

output "host_ro" {
  description = "Read-only (replica) service FQDN."
  value       = "${var.name}-ro.${var.namespace}.svc"
}

output "port" {
  description = "PostgreSQL port."
  value       = 5432
}

output "database" {
  description = "Application database name."
  value       = var.database
}

output "app_secret" {
  description = "Secret in the cluster namespace with the application credentials (username, password, dbname, host, port, uri, jdbc-uri)."
  value       = "${var.name}-app"
}

output "kv_path" {
  description = "OpenBao KV v2 path with username/password/dbname/port (when push_credentials = true)."
  value       = local.kv_path
  depends_on  = [kubernetes_manifest.push_app_credentials]
}
