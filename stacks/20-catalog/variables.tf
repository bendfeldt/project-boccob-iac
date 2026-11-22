# Common variables (environment, base_domain, registry_host, kubeconfig_path,
# ha, cluster_cidrs) come from _common.tf.

variable "storage_class" {
  description = "StorageClass for persistent volumes (null = cluster default)."
  type        = string
  default     = null
}

variable "layers" {
  description = "Data layers: one Polaris catalog `<layer>` with base location s3://lakehouse-<layer>/iceberg each."
  type        = list(string)
  default     = ["raw", "clean", "consolidated", "curated"]
}

variable "principals" {
  description = "Polaris service principals: name => catalog => catalog privileges. Credentials: kv/catalog/polaris/principals/<name>."
  type = map(object({
    catalog_privileges = map(list(string))
  }))
  default = {
    # Trino reads and writes tables of every layer (dbt, maintenance, erasure)
    trino = {
      catalog_privileges = {
        raw          = ["CATALOG_MANAGE_CONTENT"]
        clean        = ["CATALOG_MANAGE_CONTENT"]
        consolidated = ["CATALOG_MANAGE_CONTENT"]
        curated      = ["CATALOG_MANAGE_CONTENT"]
      }
    }
    # dlt index stage of the Dagster code location: raw only
    ingest = {
      catalog_privileges = {
        raw = ["CATALOG_MANAGE_CONTENT"]
      }
    }
  }
}

variable "polaris_s3_user" {
  description = "S3 user (stack 12, kv/storage/s3-users/<name>) Polaris uses for table metadata and purges."
  type        = string
  default     = "lakehouse-catalog"
}

variable "polaris_replicas" {
  description = "Polaris pods (null = 1, or 2 with ha=true)."
  type        = number
  default     = null
}

variable "polaris_resources" {
  description = "Polaris container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "448Mi" }
    limits   = { memory = "768Mi" }
  }
}

variable "polaris_oidc_enabled" {
  description = "Also accept Keycloak tokens (authentication type `mixed`, client `polaris`). false = Polaris-internal principals only (see docs/data-plane.md)."
  type        = bool
  default     = false
}

variable "postgres_instances" {
  description = "Instances of the Polaris metastore cluster (null = 1, or 3 with ha=true)."
  type        = number
  default     = null
}

variable "postgres_storage_size" {
  description = "PGDATA size of the Polaris metastore."
  type        = string
  default     = "1Gi"
}

variable "postgres_resources" {
  description = "Resources per PostgreSQL instance of the Polaris metastore."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "30m", memory = "128Mi" }
    limits   = { memory = "384Mi" }
  }
}

variable "catalog_client_namespaces" {
  description = "Namespaces whose pods may call the Polaris API (port 8181)."
  type        = list(string)
  default     = ["query", "orchestration"]
}

variable "metrics_namespaces" {
  description = "Namespaces allowed to scrape the Polaris management port (8182, /q/metrics)."
  type        = list(string)
  default     = ["observability"]
}

variable "service_monitors" {
  description = "Create ServiceMonitors (needs the Prometheus operator CRDs from the ops stack)."
  type        = bool
  default     = false
}

variable "catalog_resource_quota" {
  description = "ResourceQuota of the catalog namespace."
  type        = map(string)
  default = {
    "requests.memory" = "3Gi"
    "limits.memory"   = "6Gi"
    "pods"            = "15"
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
