output "cronjob" {
  description = "Name of the CronJob (run a given day: kubectl create job --from=cronjob/<name>, env ARCHIVE_DAY)."
  value       = kubernetes_cron_job_v1.this.metadata[0].name
}
