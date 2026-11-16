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
  description = "Operator image from module.versions.images[\"cloudnative-pg\"]."
  type = object({
    repository = string
    tag        = string
    digest     = string
    tag_digest = string
  })
}

variable "ha" {
  description = "HA profile: 2 operator replicas."
  type        = bool
  default     = false
}

variable "resources" {
  description = "Operator resources."
  type        = any
  default     = { requests = { cpu = "20m", memory = "100Mi" }, limits = { memory = "256Mi" } }
}
