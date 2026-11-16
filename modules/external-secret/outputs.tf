output "secret_name" {
  description = "Kubernetes Secret synced from OpenBao (exists when this output resolves)."
  value       = var.name
  depends_on  = [kubernetes_manifest.this]
}
