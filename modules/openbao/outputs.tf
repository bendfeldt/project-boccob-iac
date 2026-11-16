output "name" {
  description = "Release / StatefulSet name."
  value       = helm_release.this.name
}

output "url" {
  description = "In-cluster API address."
  value       = "https://${local.name}.${var.namespace}.svc:8200"
}

output "tls_secret" {
  description = "Secret with the listener certificate (ca.crt = bootstrap CA)."
  value       = local.tls_name
}

output "service_account" {
  description = "ServiceAccount of the server pods."
  value       = local.name
}
