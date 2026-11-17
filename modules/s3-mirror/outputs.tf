output "cronjob" {
  description = "Name of the CronJob (trigger on demand: kubectl create job --from=cronjob/<name>)."
  value       = kubernetes_cron_job_v1.this.metadata[0].name
}
