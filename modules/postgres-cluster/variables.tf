variable "name" {
  description = "Cluster name. Services: <name>-rw (primary), <name>-ro (replicas), <name>-r (any)."
  type        = string
}

variable "namespace" {
  description = "Namespace for the cluster (convention: database; needs allow_kube_api and secrets_access in its baseline)."
  type        = string
}

variable "image" {
  description = "Full PostgreSQL operand image reference (module.versions.images[\"postgresql\"].ref)."
  type        = string
}

variable "instances" {
  description = "Number of PostgreSQL instances: 1 (dev) or >= 3 (HA: primary + replicas with automated failover)."
  type        = number
  default     = 1
}

variable "database" {
  description = "Application database created at bootstrap."
  type        = string
}

variable "owner" {
  description = "Owner role of the application database (defaults to the database name)."
  type        = string
  default     = null
}

variable "storage_size" {
  description = "PGDATA volume size per instance."
  type        = string
  default     = "1Gi"
}

variable "wal_storage_size" {
  description = "Separate WAL volume size per instance (null = WAL on the PGDATA volume)."
  type        = string
  default     = null
}

variable "storage_class" {
  description = "StorageClass (null = cluster default)."
  type        = string
  default     = null
}

variable "resources" {
  description = "Resources per instance."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "192Mi" }
    limits   = { memory = "512Mi" }
  }
}

variable "parameters" {
  description = "postgresql.conf parameters."
  type        = map(string)
  default     = {}
}

variable "synchronous_replicas" {
  description = "Number of synchronous standbys (quorum, method any). 0 = asynchronous replication."
  type        = number
  default     = 0
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer for the server certificate."
  type        = string
  default     = "openbao-pki"
}

variable "backup" {
  description = <<-EOT
    Continuous backup (base backups + WAL archive) to S3-compatible object
    storage with the in-tree Barman Cloud integration. null = no backups (dev).
    credentials_secret must exist in the cluster namespace with the keys
    access_key_id / secret_access_key (sync it with modules/external-secret).
    ca_secret: Secret (not ConfigMap: CloudNativePG reads endpointCA from a
    Secret) in the cluster namespace with the CA of the S3 endpoint (key ca.crt).
  EOT
  type = object({
    destination_path   = string
    endpoint_url       = string
    credentials_secret = string
    access_key_id_key  = optional(string, "access_key_id")
    secret_key_key     = optional(string, "secret_access_key")
    ca_secret          = optional(string, "platform-ca")
    retention_policy   = optional(string, "30d")
    schedule           = optional(string, "0 0 2 * * *")
    immediate          = optional(bool, true)
    # server-side encryption requested for every backup object (AES256 = SSE-S3)
    encryption = optional(string)
  })
  default = null
}

variable "push_credentials" {
  description = "Push the generated application credentials to OpenBao at kv/<kv_path> so workloads in other namespaces can sync them."
  type        = bool
  default     = true
}

variable "kv_path" {
  description = "OpenBao KV v2 path for the application credentials (default: database/<name>)."
  type        = string
  default     = null
}

variable "push_store" {
  description = "ClusterSecretStore with write access to OpenBao."
  type        = string
  default     = "openbao-push"
}

variable "pod_monitor" {
  description = "Create a PodMonitor (needs the Prometheus operator CRDs — enabled by the ops stack)."
  type        = bool
  default     = false
}

variable "extra_spec" {
  description = "Escape hatch: extra top-level fields merged into the Cluster spec (e.g. plugins for the Barman Cloud plugin, managed roles)."
  type        = any
  default     = {}
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}

variable "store_kind" {
  description = "Kind of push_store: ClusterSecretStore (legacy) or SecretStore (the namespace's own store)."
  type        = string
  default     = "SecretStore"
}
