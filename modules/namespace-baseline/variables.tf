variable "name" {
  description = "Namespace name."
  type        = string
}

variable "create_namespace" {
  description = "Create the namespace. Set false to apply the baseline to an existing namespace."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Extra labels for the namespace and the baseline objects."
  type        = map(string)
  default     = {}
}

variable "pod_security_level" {
  description = "Pod Security Standard enforced in the namespace (restricted | baseline | privileged). Anything below `restricted` needs a justification in the calling stack."
  type        = string
  default     = "restricted"
  validation {
    condition     = contains(["restricted", "baseline", "privileged"], var.pod_security_level)
    error_message = "pod_security_level must be restricted, baseline or privileged."
  }
}

variable "secrets_access" {
  description = "Allow ExternalSecrets in this namespace to use the cluster-wide OpenBao ClusterSecretStores (namespace label boccob.io/secrets-access=true)."
  type        = bool
  default     = false
}

# --- network policy ------------------------------------------------------------
variable "allow_dns" {
  description = "Allow egress to cluster DNS."
  type        = bool
  default     = true
}

variable "allow_same_namespace" {
  description = "Allow all traffic between pods of this namespace."
  type        = bool
  default     = true
}

variable "allow_kube_api" {
  description = "Allow egress to the Kubernetes API server (operators, controllers, anything using a ServiceAccount against the API)."
  type        = bool
  default     = false
}

variable "ingress_controller_ports" {
  description = "Container ports the ingress controller (Traefik in kube-system) may reach in this namespace. Empty = no ingress from the ingress controller."
  type        = list(number)
  default     = []
}

variable "ingress_controller" {
  description = "Where the ingress controller pods live."
  type = object({
    namespace  = string
    pod_labels = map(string)
  })
  default = {
    namespace  = "kube-system"
    pod_labels = { "app.kubernetes.io/name" = "traefik" }
  }
}

variable "allow_ingress_hosts" {
  description = "Allow egress to the ingress controller, i.e. let pods call other platform services through their public hostname (<svc>.<base_domain>), as OIDC clients must do for the Keycloak issuer URL."
  type        = bool
  default     = false
}

variable "ingress_controller_entrypoint_ports" {
  description = "Container ports of the ingress controller entrypoints (Traefik websecure/web)."
  type        = list(number)
  default     = [8443, 8000]
}

variable "ingress_rules" {
  description = <<-EOT
    Explicit ingress allows. One NetworkPolicy `allow-in-<name>` per rule.
    `from_namespaces` are matched on kubernetes.io/metadata.name; `from_pod_labels`
    narrows them to pods; `from_cidrs` adds ipBlocks. Empty `ports` = all ports.
  EOT
  type = list(object({
    name            = string
    pod_selector    = optional(map(string), {})
    from_namespaces = optional(list(string), [])
    from_pod_labels = optional(map(string), {})
    from_cidrs      = optional(list(string), [])
    ports           = optional(list(number), [])
    protocol        = optional(string, "TCP")
  }))
  default = []
}

variable "egress_rules" {
  description = <<-EOT
    Explicit egress allows. One NetworkPolicy `allow-out-<name>` per rule.
    Same shape as ingress_rules with to_* instead of from_*.
  EOT
  type = list(object({
    name          = string
    pod_selector  = optional(map(string), {})
    to_namespaces = optional(list(string), [])
    to_pod_labels = optional(map(string), {})
    to_cidrs      = optional(list(string), [])
    ports         = optional(list(number), [])
    protocol      = optional(string, "TCP")
  }))
  default = []
}

# --- quota / limits ------------------------------------------------------------
variable "resource_quota" {
  description = "ResourceQuota `hard` map (e.g. { \"requests.cpu\" = \"2\", \"requests.memory\" = \"4Gi\", \"limits.memory\" = \"8Gi\", pods = \"30\" }). Empty = no quota."
  type        = map(string)
  default     = {}
}

variable "limit_range" {
  description = "Default container requests/limits applied when a pod does not set them. null = no LimitRange."
  type = object({
    default_request = optional(map(string), { cpu = "20m", memory = "64Mi" })
    default_limit   = optional(map(string), { memory = "256Mi" })
    max             = optional(map(string), {})
  })
  default = {}
}

# --- trust ---------------------------------------------------------------------
variable "ca_bundle_pem" {
  description = "PEM bundle of the platform CA(s). When set, ConfigMap `platform-ca` (key ca.crt) is created so workloads can mount the internal trust anchors."
  type        = string
  default     = null
}
