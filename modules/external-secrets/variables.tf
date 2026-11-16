variable "namespace" {
  description = "Namespace to install into (must already carry the namespace baseline)."
  type        = string
}

variable "chart" {
  description = "Chart coordinates from module.versions.charts[...]."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "image" {
  description = "Image from module.versions.images[\"external-secrets\"]."
  type = object({
    repository = string
    tag        = string
    digest     = string
    tag_digest = string
  })
}

variable "ha" {
  description = "HA profile: 2 replicas with leader election + PodDisruptionBudgets."
  type        = bool
  default     = false
}

variable "resources" {
  description = "Resources for each of the three deployments."
  type        = any
  default     = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
}
