variable "environment" {
  description = "Environment name, used in CA subject names."
  type        = string
}

variable "openbao_url" {
  description = "In-cluster OpenBao address, published as issuing/CRL URL in certificates."
  type        = string
}

variable "kv_mount" {
  description = "Path of the KV v2 secrets engine."
  type        = string
  default     = "kv"
}

variable "pki_allowed_domains" {
  description = "DNS domains the platform PKI role may issue for (subdomains included)."
  type        = list(string)
}

variable "pki_root_ttl_hours" {
  description = "Root CA lifetime."
  type        = number
  default     = 87600
}

variable "pki_intermediate_ttl_hours" {
  description = "Intermediate (issuing) CA lifetime."
  type        = number
  default     = 43800
}

variable "pki_max_leaf_ttl_hours" {
  description = "Maximum lifetime of issued leaf certificates."
  type        = number
  default     = 2160
}

variable "cert_manager" {
  description = "Identity cert-manager uses to request certificates (kubernetes auth)."
  type = object({
    service_account = string
    namespace       = string
    audience        = string
  })
}

variable "external_secrets" {
  description = "Identity of the External Secrets Operator controller (kubernetes auth)."
  type = object({
    service_account = string
    namespace       = string
  })
}
