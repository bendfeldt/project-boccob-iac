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
  description = <<-EOT
    Source: endpoint (https URL), Secret with access_key_id / secret_access_key,
    and the buckets to copy. Each bucket lands below <target bucket>/<target
    prefix>/<bucket>/. propagate_deletes = true also removes objects at the
    target that no longer exist at the source (lake buckets: erasure and
    retention must reach the copy); false keeps everything that ever reached
    the target (backups: a compromised platform cannot delete the copy).
  EOT
  type = object({
    endpoint           = string
    credentials_secret = string
    buckets = list(object({
      name              = string
      propagate_deletes = optional(bool, false)
    }))
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
