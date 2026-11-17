output "url" {
  description = "In-cluster HTTPS base URL of Loki (push: /otlp, /loki/api/v1/push; query: /loki/api/v1/...)."
  value       = "https://${local.host}:3100"
}

output "service" {
  description = "Loki Service name."
  value       = local.name
}
