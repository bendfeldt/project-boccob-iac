variable "bootstrap_ca_pem" {
  description = "Public certificate of the bootstrap CA (signs OpenBao's listener certificate). Injected by scripts/tofu.sh."
  type        = string
}

variable "pki_extra_allowed_domains" {
  description = "Additional DNS domains the platform PKI may issue for (base_domain and cluster-internal names are always allowed)."
  type        = list(string)
  default     = []
}

variable "pki_max_leaf_ttl_hours" {
  description = "Maximum lifetime of issued leaf certificates."
  type        = number
  default     = 2160
}
