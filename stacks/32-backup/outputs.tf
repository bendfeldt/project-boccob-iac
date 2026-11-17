output "rpo_minutes" {
  description = "Documented recovery point objective (minutes)."
  value       = var.rpo_minutes
}

output "rto_minutes" {
  description = "Documented recovery time objective (minutes)."
  value       = var.rto_minutes
}

output "openbao_snapshot_cronjob" {
  description = "CronJob of the OpenBao snapshot (namespace backup)."
  value       = module.openbao_snapshot.cronjob
}

output "offsite_cronjob" {
  description = "CronJob of the off-site copy (null when off)."
  value       = var.offsite == null ? null : module.offsite_copy[0].cronjob
}
