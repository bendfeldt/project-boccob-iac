output "service" {
  description = "Service name (port 80 -> 3000, HTTPS)."
  value       = var.name
}

output "role_attribute_path" {
  description = "Rendered JMESPath that maps Keycloak groups to Grafana roles."
  value       = local.role_path
}
