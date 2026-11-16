output "namespace" {
  description = "Namespace the CloudNativePG operator runs in."
  value       = helm_release.this.namespace
}
