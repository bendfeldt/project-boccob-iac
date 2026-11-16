output "namespace" {
  description = "Namespace cert-manager runs in (also the namespace for ClusterIssuer secrets)."
  value       = helm_release.this.namespace
}

output "service_account" {
  description = "ServiceAccount of the cert-manager controller."
  value       = "cert-manager"
}
