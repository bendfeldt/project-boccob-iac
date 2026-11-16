output "host" {
  description = "Hostname served by this ingress."
  value       = var.host
}

output "url" {
  description = "External URL."
  value       = "https://${var.host}"
}

output "tls_secret" {
  description = "Secret holding the ingress certificate issued by the platform PKI."
  value       = "${var.name}-ingress-tls"
}
