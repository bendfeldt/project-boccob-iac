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
    Off-site copy to a second S3 target (null = off). Two separate target buckets,
    each with its own credentials (operator-written OpenBao KV paths below kv/
    with the properties access-key / secret-key):
    - backups (bucket/prefix/credentials): platform-backup, never deleted at the
      target; the target bucket should have versioning, object lock (COMPLIANCE)
      and default encryption.
    - lake: the four lakehouse buckets, read with the S3 user
      platform-offsite-reader; deletions are propagated (rc mirror --remove) so
      that erasure and retention reach the copy. Its target bucket must have NO
      object lock and, if versioned, a lifecycle rule that expires noncurrent
      versions within lake.max_noncurrent_days: every run checks this first and
      refuses otherwise. Set lake = null to copy backups only.
    endpoint/cidrs/namespaces/port: where the target lives (NetworkPolicy egress);
    the target CA must be in the platform-ca bundle.
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
    lake = object({
      bucket              = string
      prefix              = optional(string, "")
      credentials         = optional(string, "backup/offsite-lake-s3")
      schedule            = optional(string, "15 */6 * * *")
      max_noncurrent_days = optional(number, 7)
      buckets             = optional(list(string), ["lakehouse-raw", "lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"])
    })
  })
  default = null
  validation {
    condition     = var.offsite == null ? true : (var.offsite.lake == null ? true : var.offsite.lake.bucket != var.offsite.bucket)
    error_message = "offsite.lake.bucket must differ from offsite.bucket: backups keep object lock, the lake copy must not (erasure)."
  }
}

variable "resources" {
  description = "Resources of the backup Job containers (null = module defaults)."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = null
}
