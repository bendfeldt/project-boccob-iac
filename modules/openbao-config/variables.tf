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

variable "namespace_stores" {
  description = <<-EOT
    Per-namespace External Secrets access (replaces the cluster-wide stores).
    For every namespace: role eso-<ns>-read (bound to ServiceAccount eso-read in
    that namespace) reads kv/<ns>/* plus the listed cross-namespace `reads`;
    role eso-<ns>-push (ServiceAccount eso-push) writes kv/<ns>/* only, and
    never the `deny_write` paths (e.g. a pepper written by its own Job).
  EOT
  type = map(object({
    reads      = optional(list(string), [])
    deny_write = optional(list(string), [])
  }))
  default = {}
}

variable "legacy_eso_roles" {
  description = "Create the legacy cluster-wide ESO roles external-secrets / external-secrets-push (kv/* read / write, bound to the ESO controller ServiceAccount). Only needed while ClusterSecretStores exist."
  type        = bool
  default     = false
}
