variable "name" {
  description = "Name of the Deployment and Service."
  type        = string
  default     = "opa"
}

variable "namespace" {
  description = "Namespace (convention: query, next to Trino)."
  type        = string
}

variable "image" {
  description = "Full OPA image reference (module.versions.images[\"opa\"].ref)."
  type        = string
}

variable "replicas" {
  description = "OPA pods. >1 adds a PodDisruptionBudget and topology spread (OPA is stateless: every pod downloads the bundle itself)."
  type        = number
  default     = 1
}

variable "bundle_ref" {
  description = "Digest-pinned OCI reference of the policy bundle published by the solution repository: <registry>/<repo>@sha256:<digest> (dist/opa/bundle.ref)."
  type        = string
  validation {
    condition     = can(regex("^[^/]+/.+@sha256:[0-9a-f]{64}$", var.bundle_ref))
    error_message = "bundle_ref must be pinned by digest: <registry>/<repository>@sha256:<64 hex>."
  }
}

variable "registry_ca_pem" {
  description = "PEM CA certificate of the OCI registry (null = the registry certificate chains to the platform CA bundle)."
  type        = string
  default     = null
}

variable "registry_credentials_secret" {
  description = "Optional Secret with keys username / password for a registry that needs authentication for pulls (null = anonymous pull)."
  type        = string
  default     = null
}

variable "bundle_polling_seconds" {
  description = "Minimum / maximum delay between bundle polls. The reference is pinned by digest, so polling only repairs a failed download."
  type = object({
    min = number
    max = number
  })
  default = { min = 60, max = 300 }
}

variable "decision_logs" {
  description = "Write every decision as a JSON line to stdout (audit trail of access decisions)."
  type        = bool
  default     = true
}

variable "tls" {
  description = "Serve the API over HTTPS with a certificate from the platform PKI."
  type        = bool
  default     = true
}

variable "client_pod_labels" {
  description = "Labels of the pods that may query OPA (API port). Everything else is denied by NetworkPolicy."
  type        = map(string)
}

variable "metrics_namespaces" {
  description = "Namespaces allowed to scrape the diagnostic port (8282: /metrics, /health)."
  type        = list(string)
  default     = ["observability"]
}

variable "registry_egress_cidrs" {
  description = "CIDRs of the OCI registry (NetworkPolicy egress)."
  type        = list(string)
}

variable "registry_port" {
  description = "Port of the OCI registry."
  type        = number
  default     = 5000
}

variable "resources" {
  description = "Container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "20m", memory = "64Mi" }
    limits   = { memory = "256Mi" }
  }
}

variable "log_level" {
  description = "OPA log level (debug | info | error)."
  type        = string
  default     = "info"
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer for the server certificate."
  type        = string
  default     = "openbao-pki"
}

variable "ca_configmap" {
  description = "ConfigMap in the namespace with the platform CA bundle (key ca.crt)."
  type        = string
  default     = "platform-ca"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
