output "metrics_port" {
  description = "Port of the collector's own Prometheus metrics (otelcol_*)."
  value       = 8888
}

output "config" {
  description = "Rendered collector configuration (no secrets), for review and `otelcol-k8s validate`."
  value       = yamlencode(local.config)
}
