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
variable "postgres_instances" {
  description = "Instances per PostgreSQL cluster created by this stack (null = 1, or 3 with ha=true)."
  type        = number
  default     = null
}

variable "postgres_storage_size" {
  description = "PGDATA size of the Keycloak database."
  type        = string
  default     = "1Gi"
}

variable "postgres_resources" {
  description = "Resources per PostgreSQL instance of the Keycloak database."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "192Mi" }
    limits   = { memory = "512Mi" }
  }
}

variable "postgres_client_namespaces" {
  description = "Namespaces whose pods may connect to PostgreSQL clusters in the database namespace (port 5432)."
  type        = list(string)
  default     = ["identity", "catalog", "orchestration", "observability"]
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
  description = "Additional buckets (name => { versioning }), merged over the contract buckets defined in main.tf (lakehouse-raw/clean/consolidated/curated, platform-backup, platform-logs)."
  type = map(object({
    versioning = optional(bool, true)
  }))
  default = {}
}

variable "s3_users" {
  description = "Additional S3 users (access key => bucket grants), merged over the built-in ones (lakehouse-catalog, lakehouse-ingest, platform-backup, platform-logs). Secret keys are generated and stored in OpenBao at kv/storage/s3-users/<name>."
  type = map(object({
    read_write_buckets = optional(list(string), [])
    read_only_buckets  = optional(list(string), [])
  }))
  default = {}
}

variable "s3_client_namespaces" {
  description = "Namespaces whose pods may reach the RustFS S3 API (port 9000) directly."
  type        = list(string)
  default     = ["database", "secrets", "catalog", "query", "orchestration", "observability"]
}

# --- Keycloak --------------------------------------------------------------------
variable "keycloak_replicas" {
  description = "Keycloak pods (null = 1, or 2 with ha=true)."
  type        = number
  default     = null
}

variable "keycloak_resources" {
  description = "Keycloak container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "100m", memory = "640Mi" }
    limits   = { memory = "1280Mi" }
  }
}

variable "oidc_clients" {
  description = "OIDC clients of the lakehouse realm, merged over the built-in defaults (trino, polaris, dagster, grafana, openbao). See modules/keycloak for the object shape."
  type        = any
  default     = {}
}

variable "keycloak_client_namespaces" {
  description = "Namespaces whose pods may reach Keycloak directly on its Service (port 8443). OIDC clients normally use the public hostname instead (allow_ingress_hosts in their namespace baseline)."
  type        = list(string)
  default     = []
}

# --- backup / encryption (ops work package) ---------------------------------------
variable "rustfs_sse_enabled" {
  description = "Generate an SSE-S3 master key for RustFS (kv/storage/rustfs-sse) so clients can request server-side encryption (used for backups)."
  type        = bool
  default     = true
}

variable "postgres_backup" {
  description = "Continuous backup (base backups + WAL, PITR) of the PostgreSQL clusters of this stack to s3://platform-backup/postgres/<cluster>. null = off."
  type = object({
    retention_policy = optional(string, "7d")
    schedule         = optional(string, "0 30 1 * * *")
  })
  default = {}
}
