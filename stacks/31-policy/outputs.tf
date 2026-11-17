output "policy_mode" {
  description = "Cluster-wide policy mode."
  value       = module.policies.mode
}

output "cosign_public_keys" {
  description = "Public keys (PEM) of the solution signing key, all versions. Public material."
  value       = local.cosign_public_keys
}
