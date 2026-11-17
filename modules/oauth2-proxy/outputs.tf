output "service" {
  description = "Service name (port 8443, HTTPS)."
  value       = kubernetes_service_v1.this.metadata[0].name
  depends_on  = [kubernetes_deployment_v1.this]
}

output "host" {
  description = "In-cluster host name (matches the server certificate)."
  value       = local.host
}

output "pod_labels" {
  description = "Selector labels of the proxy pods."
  value       = local.selector_labels
}
