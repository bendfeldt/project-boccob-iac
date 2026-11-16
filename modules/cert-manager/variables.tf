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

variable "images" {
  description = "Images from module.versions.images: controller, webhook, cainjector, acmesolver."
  type = map(object({
    repository = string
    tag        = string
    digest     = string
    tag_digest = string
  }))
}

variable "ha" {
  description = "HA profile: 2 replicas with leader election + PodDisruptionBudgets."
  type        = bool
  default     = false
}

variable "resources" {
  description = "Resources per component (controller, webhook, cainjector)."
  type        = map(any)
  default = {
    controller = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    webhook    = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "128Mi" } }
    cainjector = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
  }
}
