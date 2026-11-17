output "loki_url" {
  description = "In-cluster Loki URL (tenants: platform, audit)."
  value       = module.loki.url
}

output "prometheus_url" {
  description = "In-cluster Prometheus URL."
  value       = module.prometheus.url
}
