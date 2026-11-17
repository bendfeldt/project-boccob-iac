output "namespace" {
  description = "Namespace Kyverno runs in (also the only namespace PolicyExceptions are honoured from)."
  value       = helm_release.this.namespace
}
