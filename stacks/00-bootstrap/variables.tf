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
