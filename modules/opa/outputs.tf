output "url" {
  description = "Base URL of the OPA API inside the cluster."
  value       = "${local.scheme}://${local.host}:8181"
  depends_on  = [kubernetes_deployment_v1.this]
}

output "service" {
  description = "Service name."
  value       = kubernetes_service_v1.this.metadata[0].name
}

output "pod_labels" {
  description = "Selector labels of the OPA pods."
  value       = local.selector_labels
}
