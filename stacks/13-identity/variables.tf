# Common variables come from _common.tf.

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

variable "rustfs_sse_enabled" {
  description = "Same value as in stack 12: RustFS has an SSE-S3 master key, so the keycloak-db backups request server-side encryption (AES256)."
  type        = bool
  default     = true
}

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

variable "postgres_backup" {
  description = "Continuous backup (base backups + WAL, PITR) of keycloak-db to s3://platform-backup/postgres/<cluster>. null = off."
  type = object({
    retention_policy = optional(string, "7d")
    schedule         = optional(string, "0 30 1 * * *")
  })
  default = {}
}
