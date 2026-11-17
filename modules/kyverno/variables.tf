variable "namespace" {
  description = "Namespace for Kyverno (created by the calling stack with modules/namespace-baseline, allow_kube_api = true)."
  type        = string
}

variable "chart" {
  description = "Kyverno chart (module.versions.charts[\"kyverno\"])."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "images" {
  description = "Mirrored images: admission (kyverno), pre (kyvernopre), background, reports. Objects from module.versions.images."
  type = map(object({
    registry        = string
    repository_path = string
    tag_digest      = string
  }))
}

variable "ha" {
  description = "HA profile: 3 admission controller replicas, 2 of the other controllers, PodDisruptionBudgets."
  type        = bool
  default     = false
}

variable "background_controller_enabled" {
  description = "Deploy the background controller (generate / mutate-existing rules). The shipped policies only validate, so it is off by default."
  type        = bool
  default     = false
}

variable "registry_ca_pem" {
  description = "PEM bundle of the CA(s) that signed the certificate of the Zot registry. Kyverno fetches image signatures from the registry and must trust it."
  type        = string
}

variable "excluded_namespaces" {
  description = "Namespaces the Kyverno admission webhooks never see (namespaceSelector of the webhook configurations). kube-system must stay excluded: it holds the k3s system pods the cluster needs to recover."
  type        = list(string)
  default     = ["kube-system"]
}

variable "resources" {
  nullable    = false
  description = "Container resources per controller (admission, background, reports)."
  type = map(object({
    requests = map(string)
    limits   = map(string)
  }))
  default = {
    admission  = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "384Mi" } }
    background = { requests = { cpu = "20m", memory = "64Mi" }, limits = { memory = "128Mi" } }
    reports    = { requests = { cpu = "20m", memory = "64Mi" }, limits = { memory = "256Mi" } }
  }
}

variable "background_scan_interval" {
  description = "Interval of the background scan that produces PolicyReports for existing resources."
  type        = string
  default     = "1h"
}
