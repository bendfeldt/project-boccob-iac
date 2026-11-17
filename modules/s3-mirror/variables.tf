variable "name" {
  description = "Name of the CronJob and its ConfigMap."
  type        = string
  default     = "offsite-copy"
}

variable "namespace" {
  description = "Namespace (needs egress to the source and the target endpoint)."
  type        = string
}

variable "image" {
  description = "rc (RustFS S3 CLI) image reference."
  type        = string
}

variable "schedule" {
  description = "Cron schedule (UTC)."
  type        = string
  default     = "45 */6 * * *"
}

variable "source_s3" {
  description = "Source: endpoint (https URL), bucket, optional prefix, Secret with access_key_id / secret_access_key."
  type = object({
    endpoint           = string
    bucket             = string
    prefix             = optional(string, "")
    credentials_secret = string
  })
}

variable "target_s3" {
  description = "Target (off-site): endpoint, bucket, optional prefix, Secret with access_key_id / secret_access_key."
  type = object({
    endpoint           = string
    bucket             = string
    prefix             = optional(string, "")
    credentials_secret = string
  })
}

variable "ca_configmap" {
  description = "ConfigMap with the CA bundle (key ca.crt) trusted for both endpoints."
  type        = string
  default     = "platform-ca"
}

variable "resources" {
  description = "Container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "20m", memory = "64Mi" }
    limits   = { memory = "512Mi" }
  }
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
