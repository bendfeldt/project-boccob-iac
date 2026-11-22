# Common variables come from _common.tf.

variable "dagster_code_location_image" {
  description = "Digest-pinned code location image published by the solution repository (dist/image/image.ref)."
  type        = string
}

variable "solution_env" {
  description = "Extra / overriding non-secret environment for the code location and run pods (e.g. INGEST_START_DATE, DBT_THREADS)."
  type        = map(string)
  default     = {}
}

variable "schedules_enabled" {
  description = "Start the solution's schedules automatically (SCHEDULES_ENABLED)."
  type        = bool
  default     = false
}

variable "s3_user" {
  description = "S3 user (stack 12) of the run pods: rw lakehouse-raw, read on the other layers."
  type        = string
  default     = "lakehouse-orchestration"
}

variable "purge_s3_user" {
  description = "S3 user (stack 12) that may delete object versions on the layer buckets (PURGE_S3_*: erasure, retention, maintenance)."
  type        = string
  default     = "lakehouse-purge"
}

variable "compute_logs_s3" {
  description = "Step logs also to S3 (dagster_aws S3ComputeLogManager, bucket dagster-compute-logs, S3 user dagster-compute-logs; both registered in the stack 12 tfvars). Needs dagster-aws in the code location image (solution >= 0112d93) - with an older image the run pods cannot load the instance. false = stdout only."
  type        = bool
  default     = true
}

variable "purge_jobs" {
  description = "Dagster jobs that may attach the purge credential (Secret lakehouse-purge-env, PURGE_S3_*) through their tag dagster-k8s/config; every other run, and the code server, runs without it."
  type        = list(string)
  default     = ["erasure", "retention", "iceberg_maintenance"]
}

variable "polaris_principal" {
  description = "Polaris principal of the ingestion (index) stage (stack 20)."
  type        = string
  default     = "ingest"
}

variable "trino_service_account" {
  description = "Trino service account of Dagster/dbt (stack 21; groups data-engineer + pii-reader)."
  type        = string
  default     = "svc-dagster"
}

variable "dagster_ui_groups" {
  description = "Keycloak groups allowed into the Dagster UI. Privileged: launching runs (with run config and tags) is acting as svc-dagster, Dagster OSS has no roles. test/prod tfvars: platform-admin only."
  type        = list(string)
  default     = ["platform-admin", "data-engineer"]
}

variable "max_concurrent_runs" {
  description = "Runs in progress at once."
  type        = number
  default     = 4
}

variable "webserver_replicas" {
  description = "Webserver pods (null = 1, or 2 with ha=true)."
  type        = number
  default     = null
}

variable "storage_class" {
  description = "StorageClass for persistent volumes (null = cluster default)."
  type        = string
  default     = null
}

variable "postgres_instances" {
  description = "Instances of the Dagster database cluster (null = 1, or 3 with ha=true)."
  type        = number
  default     = null
}

variable "postgres_storage_size" {
  description = "PGDATA size of the Dagster database."
  type        = string
  default     = "1Gi"
}

variable "postgres_resources" {
  description = "Resources per PostgreSQL instance of the Dagster database."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "30m", memory = "128Mi" }
    limits   = { memory = "384Mi" }
  }
}

variable "orchestration_resource_quota" {
  description = "ResourceQuota of the orchestration namespace."
  type        = map(string)
  default = {
    "requests.memory" = "6Gi"
    "limits.memory"   = "12Gi"
    "pods"            = "40"
  }
}

variable "postgres_backup" {
  description = "Continuous backup (base backups + WAL, PITR) of this stack's PostgreSQL cluster to s3://platform-backup/postgres/<cluster>-pg<major>. null = off."
  type = object({
    retention_policy = optional(string, "7d")
    schedule         = optional(string, "0 30 1 * * *")
    encryption       = optional(string, "AES256")
  })
  default = {}
}
