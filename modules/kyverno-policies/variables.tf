variable "namespace" {
  description = "Kyverno namespace (holds the Helm release record and the PolicyExceptions)."
  type        = string
}

variable "registry_host" {
  description = "Zot registry host[:port]; every image must start with <registry_host>/."
  type        = string
}

variable "mode" {
  description = "Cluster-wide default: Audit (violations only appear in PolicyReports and events) or Enforce (violating pods are rejected). Roll out with Audit, clear the reports, then switch."
  type        = string
  default     = "Audit"
  validation {
    condition     = contains(["Audit", "Enforce"], var.mode)
    error_message = "mode must be Audit or Enforce."
  }
}

variable "enforce_label" {
  description = "Namespaces carrying this label are enforced even while mode = Audit (namespace by namespace roll-out, and the verify smoke test)."
  type = object({
    key   = string
    value = string
  })
  default = { key = "boccob.io/policy-enforce", value = "true" }
}

variable "failure_policy" {
  description = "Ignore or Fail: API server behaviour when Kyverno does not answer. Fail only with several admission controller replicas (ha)."
  type        = string
  default     = "Ignore"
  validation {
    condition     = contains(["Ignore", "Fail"], var.failure_policy)
    error_message = "failure_policy must be Ignore or Fail."
  }
}

variable "excluded_namespaces" {
  description = "Namespaces no policy applies to."
  type        = list(string)
  default     = ["kube-system"]
}

variable "policies" {
  description = "Switch single policies off (name => false). Names: restrict-image-registries, require-image-digest, disallow-latest-tag, require-run-as-non-root, require-read-only-root-filesystem, require-requests-limits."
  type        = map(bool)
  default     = {}
}

variable "signature_public_keys" {
  description = "PEM public keys (cosign) that may sign the solution artefacts; an image is accepted when one of them verifies. Empty = no signature policy."
  type        = list(string)
  default     = []
}

variable "signature_image_globs" {
  description = "Image references that must be signed (null = <registry_host>/boccob/*, the solution artefacts)."
  type        = list(string)
  default     = null
}

variable "signature_mode" {
  description = "Audit or Enforce for the signature policy only (null = mode)."
  type        = string
  default     = null
}

variable "keyless_policies" {
  description = <<-EOT
    Upstream keyless (Sigstore) signature checks at admission. Each entry needs
    the signatures mirrored next to the image in Zot and, air-gapped, a Sigstore
    trust root (tuf_mirror or trusted_root JSON). Empty by default: upstream
    signatures are verified at mirror time (make verify-signatures) instead.
  EOT
  type = list(object({
    name           = string
    image_globs    = list(string)
    issuer         = string
    subject_regexp = string
    tuf_mirror     = optional(string)
    trusted_root   = optional(string)
    mode           = optional(string)
  }))
  default = []
}

variable "exceptions" {
  description = <<-EOT
    PolicyExceptions: workloads that legitimately cannot meet a policy. Scope =
    namespaces (required) and optional name prefixes (pod / controller names).
    Every exception carries a justification that ends up as an annotation.
  EOT
  type = list(object({
    name          = string
    policies      = list(string)
    namespaces    = list(string)
    name_prefixes = optional(list(string), [])
    justification = string
  }))
  default = []
}
