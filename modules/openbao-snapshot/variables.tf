variable "name" {
  description = "Name of the CronJob, ServiceAccount and ConfigMap."
  type        = string
  default     = "openbao-snapshot"
}

variable "namespace" {
  description = "Namespace (baseline with secrets_access, ca_bundle_pem, egress to secrets:8200 and storage:9000)."
  type        = string
}

variable "images" {
  description = "Image references: openbao (bao CLI) and rc (RustFS S3 CLI)."
  type = object({
    openbao = string
    rc      = string
  })
}

variable "schedule" {
  description = "Cron schedule (UTC). Sets the RPO of OpenBao."
  type        = string
  default     = "15 * * * *"
}

variable "openbao_addr" {
  description = "OpenBao API address (TLS, verified against the platform CA)."
  type        = string
  default     = "https://openbao.secrets.svc:8200"
}

variable "openbao_role" {
  description = "OpenBao kubernetes auth role allowed to read sys/storage/raft/snapshot (bound to this ServiceAccount)."
  type        = string
}

variable "openbao_audience" {
  description = "Audience of the projected ServiceAccount token used to log in."
  type        = string
  default     = "openbao"
}

variable "s3" {
  description = "Target: endpoint (https URL), bucket, prefix, and the Secret with access_key_id / secret_access_key."
  type = object({
    endpoint           = string
    bucket             = string
    prefix             = optional(string, "openbao")
    credentials_secret = string
    encrypt            = optional(bool, true)
  })
}

variable "lifecycle_rules" {
  description = "S3 lifecycle configuration (JSON object with Rules) imported into the bucket on every run (replaces the bucket's configuration). null = leave the bucket's lifecycle alone."
  type        = any
  default     = null
}

variable "ca_configmap" {
  description = "ConfigMap with the platform CA bundle (key ca.crt)."
  type        = string
  default     = "platform-ca"
}

variable "resources" {
  description = "Resources of each container."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "10m", memory = "32Mi" }
    limits   = { memory = "256Mi" }
  }
}

variable "history" {
  description = "Successful / failed Jobs kept for inspection."
  type        = number
  default     = 3
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
