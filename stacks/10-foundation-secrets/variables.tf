variable "openbao_replicas" {
  description = "OpenBao raft members (null = 1, or 3 with ha=true)."
  type        = number
  default     = null
}

variable "openbao_data_storage_size" {
  description = "OpenBao raft volume size per member."
  type        = string
  default     = "1Gi"
}

variable "openbao_audit_storage_size" {
  description = "OpenBao audit volume size per member."
  type        = string
  default     = "1Gi"
}

variable "openbao_resources" {
  description = "OpenBao server resources."
  type        = any
  default     = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "512Mi" } }
}

variable "storage_class" {
  description = "StorageClass for persistent volumes (null = cluster default)."
  type        = string
  default     = null
}

variable "openbao_client_namespaces" {
  description = "Namespaces whose pods may call the OpenBao API directly (ESO/cert-manager in platform-system are always allowed)."
  type        = list(string)
  default     = ["identity", "storage", "database", "catalog", "query", "orchestration", "observability", "backup"]
}
