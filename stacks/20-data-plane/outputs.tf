output "platform_ca_configured" {
  description = "True when the platform CA bundle is available to this stack."
  value       = length(local.platform_ca_pem) > 0
}
