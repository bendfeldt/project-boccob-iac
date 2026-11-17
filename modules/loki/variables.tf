variable "namespace" {
  description = "Namespace (baseline with secrets_access, ca_bundle_pem, egress to storage:9000)."
  type        = string
}

variable "chart" {
  description = "Loki chart (module.versions.charts[\"loki\"])."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "image" {
  description = "Loki image (module.versions.images[\"loki\"])."
  type = object({
    registry        = string
    repository_path = string
    tag_digest      = string
  })
}

variable "s3" {
  description = "Object storage for chunks and index: endpoint (https URL), bucket, Secret with access_key_id / secret_access_key, region."
  type = object({
    endpoint           = string
    bucket             = string
    credentials_secret = string
    region             = optional(string, "us-east-1")
  })
}

variable "tenants" {
  description = "Tenants (X-Scope-OrgID) and their retention (Loki duration, e.g. 168h). The log pipeline writes ordinary logs to `platform` and audit logs to `audit`; read access is granted per tenant (Grafana data sources)."
  type        = map(object({ retention_period = string }))
  default = {
    platform = { retention_period = "168h" }
    audit    = { retention_period = "8760h" }
  }
}

variable "default_retention_period" {
  description = "Retention for any tenant not listed in `tenants`."
  type        = string
  default     = "168h"
}

variable "replicas" {
  description = "Loki single-binary replicas. More than 1 needs a replication factor > 1 (set by the module) and enough nodes."
  type        = number
  default     = 1
}

variable "storage_size" {
  description = "Local volume (WAL, index cache, compactor working directory)."
  type        = string
  default     = "2Gi"
}

variable "storage_class" {
  description = "StorageClass (null = cluster default)."
  type        = string
  default     = null
}

variable "resources" {
  description = "Loki container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "192Mi" }
    limits   = { memory = "768Mi" }
  }
}

variable "cluster_issuer" {
  description = "ClusterIssuer of the HTTPS server certificate."
  type        = string
  default     = "openbao-pki"
}

variable "ca_configmap" {
  description = "ConfigMap with the platform CA bundle (key ca.crt) for the S3 endpoint."
  type        = string
  default     = "platform-ca"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
