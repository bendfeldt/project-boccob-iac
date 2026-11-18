output "name" {
  description = "Namespace name (use this instead of the literal so resources wait for the baseline)."
  value       = local.ns
  depends_on = [
    kubernetes_network_policy_v1.default_deny,
    kubernetes_network_policy_v1.dns,
    kubernetes_network_policy_v1.same_namespace,
    kubernetes_network_policy_v1.kube_api,
    kubernetes_limit_range_v1.this,
    kubernetes_manifest.secret_store,
  ]
}

output "ca_configmap" {
  description = "Name of the ConfigMap holding the platform CA bundle (key ca.crt), or null."
  value       = var.ca_bundle_pem == null ? null : kubernetes_config_map_v1.platform_ca[0].metadata[0].name
}

output "secret_stores" {
  description = "Names of the namespaced SecretStores (read, push), or null without secrets_access."
  value       = var.secrets_access ? { read = "openbao", push = "openbao-push", kind = "SecretStore" } : null
  depends_on  = [kubernetes_manifest.secret_store]
}
