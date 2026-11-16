output "secret_name" {
  description = "Kubernetes Secret holding the generated values (ready and pushed when this output resolves)."
  value       = var.name
  depends_on  = [kubernetes_manifest.push]
}

output "kv_path" {
  description = "OpenBao KV v2 path the values were pushed to."
  value       = var.kv_path
  depends_on  = [kubernetes_manifest.push]
}
