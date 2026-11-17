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

# --- policies ---------------------------------------------------------------------
variable "policy_mode" {
  description = "Audit (report only) or Enforce (reject). Start with Audit, work through `kubectl get policyreport -A`, then switch."
  type        = string
  default     = "Audit"
}

variable "policy_failure_policy" {
  description = "Ignore or Fail when Kyverno is unavailable (null = Fail with ha, Ignore otherwise)."
  type        = string
  default     = null
}

variable "policy_overrides" {
  description = "Switch single policies off (name => false), see modules/kyverno-policies."
  type        = map(bool)
  default     = {}
}

variable "policy_excluded_namespaces" {
  description = "Namespaces no policy applies to (kube-system: k3s system pods are pulled through the registries.yaml mirror under their upstream names)."
  type        = list(string)
  default     = ["kube-system"]
}

variable "policy_exceptions" {
  description = "Additional PolicyExceptions, appended to the built-in ones in main.tf (see modules/kyverno-policies for the shape)."
  type        = any
  default     = []
}

variable "signature_mode" {
  description = "Audit or Enforce for the solution image signature policy (null = policy_mode)."
  type        = string
  default     = null
}

variable "keyless_policies" {
  description = "Upstream keyless signature checks at admission (see modules/kyverno-policies; needs mirrored signatures and a Sigstore trust root)."
  type        = any
  default     = []
}

variable "cosign_key_name" {
  description = "Name of the OpenBao transit key (ecdsa-p256) that signs the solution artefacts."
  type        = string
  default     = "cosign-solution"
}
