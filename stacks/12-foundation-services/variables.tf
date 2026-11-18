variable "storage_class" {
  description = "StorageClass for persistent volumes (null = cluster default)."
  type        = string
  default     = null
}

variable "metrics_namespaces" {
  description = "Namespaces allowed to scrape metrics endpoints of the foundation services."
  type        = list(string)
  default     = ["observability"]
}

# --- PostgreSQL ----------------------------------------------------------------

variable "postgres_client_namespaces" {
  description = "Namespaces whose pods may connect to PostgreSQL clusters in the database namespace (port 5432)."
  type        = list(string)
  default     = ["identity", "catalog", "orchestration", "observability", "backup"]
}

# --- RustFS ----------------------------------------------------------------------
variable "rustfs_distributed" {
  description = "Distributed erasure-coded RustFS (null = follows ha)."
  type        = bool
  default     = null
}

variable "rustfs_replicas" {
  description = "RustFS nodes in distributed mode."
  type        = number
  default     = 4
}

variable "rustfs_drives_per_node" {
  description = "Data volumes per RustFS node in distributed mode."
  type        = number
  default     = 1
}

variable "rustfs_data_storage_size" {
  description = "Size of each RustFS data volume."
  type        = string
  default     = "5Gi"
}

variable "rustfs_resources" {
  description = "Resources per RustFS pod."
  type        = any
  default     = { requests = { cpu = "50m", memory = "256Mi" }, limits = { memory = "1Gi" } }
}

variable "buckets" {
  description = "Additional buckets (name => { versioning, object_lock, lifecycle }), merged over the contract buckets defined in main.tf (lakehouse-raw/clean/consolidated/curated, platform-backup, platform-logs, platform-audit). See modules/rustfs `buckets`."
  type = map(object({
    versioning = optional(bool, true)
    object_lock = optional(object({
      mode = string
      days = number
    }))
    lifecycle = optional(object({
      noncurrent_days        = optional(number)
      expired_delete_markers = optional(bool, true)
      expiration_days        = optional(number) # delete current objects after N days (log buckets)
    }))
  }))
  default = {}
}

variable "audit_archive_lock" {
  description = "Object lock of the audit archive bucket platform-audit (WORM copy of the audit trail, written by stack 30-observability). mode compliance|governance, days = default retention of every archived object."
  type = object({
    mode = string
    days = number
  })
  default = { mode = "compliance", days = 365 }
}

variable "s3_users" {
  description = "Additional S3 users (access key => bucket grants), merged over the built-in ones (lakehouse-catalog, lakehouse-ingest, platform-backup, platform-offsite-reader, platform-logs). Secret keys are generated and stored in OpenBao at kv/storage/s3-users/<name>."
  type = map(object({
    read_write_buckets = optional(list(string), [])
    read_only_buckets  = optional(list(string), [])
    purge_buckets      = optional(list(string), []) # list/get/delete objects and object versions only
  }))
  default = {}
}

variable "s3_client_namespaces" {
  description = "Namespaces whose pods may reach the RustFS S3 API (port 9000) directly."
  type        = list(string)
  default     = ["database", "secrets", "catalog", "query", "orchestration", "observability", "backup"]
}


# --- backup / encryption (ops work package) ---------------------------------------
variable "rustfs_sse_enabled" {
  description = "Generate an SSE-S3 master key for RustFS (kv/storage/rustfs-sse) so clients can request server-side encryption (used for backups)."
  type        = bool
  default     = true
}
