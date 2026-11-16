output "platform_namespace" {
  description = "Namespace holding cert-manager, External Secrets Operator and the CloudNativePG operator."
  value       = module.ns_platform.name
}
