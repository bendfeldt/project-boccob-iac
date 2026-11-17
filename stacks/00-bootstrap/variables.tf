variable "ingress_dns_rewrite" {
  description = "Make <svc>.<base_domain> resolve to Traefik from inside the cluster (CoreDNS rewrite). Needed when the site DNS does not serve these names to pods (dev); in test/prod prefer real DNS records and set false."
  type        = bool
  default     = true
}

variable "ingress_dns_rewrite_exclude" {
  description = "Names under base_domain that must NOT be rewritten to Traefik (they keep resolving through upstream DNS), e.g. the Zot registry."
  type        = list(string)
  default     = []
}

variable "traefik_replicas" {
  description = "Traefik replicas (null = 1, or 2 with ha=true)."
  type        = number
  default     = null
}

variable "metrics_namespaces" {
  description = "Namespaces allowed to scrape the metrics endpoints of the platform-system controllers."
  type        = list(string)
  default     = ["observability"]
}

variable "metrics_ports" {
  description = "Metrics ports of the platform-system controllers (cert-manager 9402, External Secrets and CloudNativePG operator 8080)."
  type        = list(number)
  default     = [9402, 8080]
}
