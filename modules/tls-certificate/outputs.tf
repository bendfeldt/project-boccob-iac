output "secret_name" {
  description = "TLS Secret (exists when this output resolves)."
  value       = var.name
  depends_on  = [kubernetes_manifest.this]
}
