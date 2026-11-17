# --- targets (documented; used by alert rules in 30-observability and by the runbook) ---
variable "rpo_minutes" {
  description = "Recovery point objective in minutes (documented target). PostgreSQL: WAL archiving (archive_timeout 5 min) gives a few minutes; OpenBao: interval of the snapshot schedule; object storage: interval of the off-site copy. Alerts fire when a backup is older than this."
  type        = number
  default     = 60
}

variable "rto_minutes" {
  description = "Recovery time objective in minutes (documented target, measured by `make restore-test`)."
  type        = number
  default     = 240
}

# --- OpenBao raft snapshots -------------------------------------------------------
variable "openbao_snapshot_schedule" {
  description = "Cron schedule (UTC) of the OpenBao raft snapshot."
  type        = string
  default     = "15 * * * *"
}

variable "openbao_snapshot_retention_days" {
  description = "Days an OpenBao snapshot is kept in platform-backup (S3 lifecycle on the prefix openbao/)."
  type        = number
  default     = 30
}

variable "noncurrent_version_retention_days" {
  description = "Days deleted/overwritten object versions in platform-backup are kept (protection against accidental or malicious deletion; also covers PostgreSQL backups removed by the barman retention policy)."
  type        = number
  default     = 14
}

# --- off-site copy ------------------------------------------------------------------
variable "offsite" {
  description = <<-EOT
    Second S3 target for an off-site copy of platform-backup (null = off).
    endpoint: https URL of the target; bucket/prefix there; credentials: OpenBao
    KV path (below kv/) with the properties access-key / secret-key, written by
    an operator (`bao kv put kv/backup/offsite-s3 access-key=.. secret-key=..`);
    cidrs/port: where the target lives (NetworkPolicy egress). The target CA must
    be in the platform-ca bundle or be the platform CA.
  EOT
  type = object({
    endpoint    = string
    bucket      = string
    prefix      = optional(string, "")
    credentials = optional(string, "backup/offsite-s3")
    cidrs       = optional(list(string), [])
    namespaces  = optional(list(string), [])
    port        = optional(number, 443)
    schedule    = optional(string, "45 */6 * * *")
    # buckets copied (each below <bucket>/<prefix>/<source bucket>/);
    # lake buckets propagate deletions so that erasure reaches the copy
    buckets = optional(list(object({
      name              = string
      propagate_deletes = optional(bool, false)
      })), [
      { name = "platform-backup" },
      { name = "lakehouse-raw", propagate_deletes = true },
      { name = "lakehouse-clean", propagate_deletes = true },
      { name = "lakehouse-consolidated", propagate_deletes = true },
      { name = "lakehouse-curated", propagate_deletes = true },
    ])
  })
  default = null
}

variable "resources" {
  description = "Resources of the backup Job containers (null = module defaults)."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = null
}
