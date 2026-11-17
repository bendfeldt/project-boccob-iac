variable "name" {
  description = "Name of the CronJob and ConfigMap."
  type        = string
  default     = "audit-archive"
}

variable "namespace" {
  description = "Namespace (egress to Loki and S3)."
  type        = string
}

variable "images" {
  description = "Image references: python (exporter, stdlib only) and rc (RustFS CLI, uploader)."
  type = object({
    python = string
    rc     = string
  })
}

variable "schedule" {
  description = "Cron schedule (UTC). Each run archives the previous UTC day."
  type        = string
  default     = "20 1 * * *"
}

variable "loki_url" {
  description = "Loki base URL (https)."
  type        = string
}

variable "tenant" {
  description = "Loki tenant holding the audit trail."
  type        = string
  default     = "audit"
}

variable "s3" {
  description = "WORM target: endpoint (https URL), bucket (created with object lock), prefix, Secret with access_key_id / secret_access_key."
  type = object({
    endpoint           = string
    bucket             = string
    prefix             = optional(string, "loki-audit")
    credentials_secret = string
  })
}

variable "page_size" {
  description = "Log lines per Loki query page."
  type        = number
  default     = 1000
}

variable "resources" {
  description = "Container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "20m", memory = "64Mi" }
    limits   = { memory = "256Mi" }
  }
}

variable "work_size" {
  description = "emptyDir size for one day of audit lines (uncompressed + compressed)."
  type        = string
  default     = "2Gi"
}

variable "ca_configmap" {
  description = "ConfigMap with the platform CA bundle (key ca.crt)."
  type        = string
  default     = "platform-ca"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
