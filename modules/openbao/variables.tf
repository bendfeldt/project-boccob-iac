variable "namespace" {
  description = "Namespace to install into (must already carry the namespace baseline)."
  type        = string
}

variable "chart" {
  description = "Chart coordinates from module.versions.charts[\"openbao\"]."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "image" {
  description = "Image from module.versions.images[\"openbao\"]."
  type = object({
    registry        = string
    repository_path = string
    tag_digest      = string
  })
}

variable "replicas" {
  description = "Raft members: 1 (dev) or 3/5 (HA). Integrated raft storage is used in every profile so snapshots work the same everywhere."
  type        = number
  default     = 1
  validation {
    condition     = contains([1, 3, 5], var.replicas)
    error_message = "replicas must be 1, 3 or 5 (raft quorum)."
  }
}

variable "tls_issuer" {
  description = "cert-manager ClusterIssuer for the listener certificate. Must NOT depend on OpenBao itself (bootstrap CA)."
  type        = string
}

variable "data_storage_size" {
  description = "Size of the raft data volume per member."
  type        = string
  default     = "1Gi"
}

variable "audit_storage_size" {
  description = "Size of the audit log volume per member (file audit device). The audit log is also written to stdout for log shipping."
  type        = string
  default     = "1Gi"
}

variable "storage_class" {
  description = "StorageClass for data and audit volumes (null = cluster default)."
  type        = string
  default     = null
}

variable "resources" {
  description = "Server container resources."
  type        = any
  default     = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "512Mi" } }
}

variable "log_level" {
  description = "Server log level."
  type        = string
  default     = "info"
}
