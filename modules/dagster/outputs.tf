output "webserver_service" {
  description = "Webserver Service (plain HTTP 80, reachable only from inside the namespace)."
  value       = "${local.name}-webserver"
  depends_on  = [helm_release.this]
}

output "webserver_url" {
  description = "In-cluster webserver URL (upstream of the oauth2-proxy)."
  value       = "http://${local.name}-webserver.${var.namespace}.svc:80"
}

output "pepper_kv_path" {
  description = "OpenBao KV path of the pseudonymisation pepper (back it up, see docs/data-plane.md)."
  value       = var.pepper_kv_path
}
