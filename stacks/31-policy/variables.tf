variable "registry_ca_file" {
  description = "File with the CA certificate of the Zot registry (null = ~/.boccob/<environment>/pki/registry-ca.crt, where the cluster scripts keep it). Public material."
  type        = string
  default     = null
}

variable "registry_cidrs" {
  description = "Networks the Zot registry lives in; Kyverno may connect to the registry port there to fetch signatures (null = cluster_cidrs: in dev the registry sits on the node network)."
  type        = list(string)
  default     = null
}

variable "metrics_namespaces" {
  description = "Namespaces allowed to scrape the Kyverno metrics endpoints (port 8000)."
  type        = list(string)
  default     = ["observability"]
}

variable "kyverno_background_controller_enabled" {
  description = "Deploy the Kyverno background controller (only needed for generate / mutate-existing policies)."
  type        = bool
  default     = false
}

variable "kyverno_resources" {
  description = "Container resources per Kyverno controller (admission, background, reports). null = module defaults (dev sized)."
  type = map(object({
    requests = map(string)
    limits   = map(string)
  }))
  default = null
}
