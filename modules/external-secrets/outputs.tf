output "namespace" {
  description = "Namespace External Secrets Operator runs in."
  value       = helm_release.this.namespace
}

output "service_account" {
  description = "ServiceAccount of the ESO controller (bound to the OpenBao kubernetes auth roles)."
  value       = "external-secrets"
}
