variable "name" {
  description = "Name of the Deployment / Service (e.g. dagster-auth)."
  type        = string
}

variable "namespace" {
  description = "Namespace (needs secrets_access, allow_ingress_hosts and the platform-ca ConfigMap)."
  type        = string
}

variable "image" {
  description = "Full oauth2-proxy image reference (module.versions.images[\"oauth2-proxy\"].ref)."
  type        = string
}

variable "replicas" {
  description = "Pods (stateless: the session lives in the encrypted cookie)."
  type        = number
  default     = 1
}

variable "public_host" {
  description = "Public hostname of the protected application (redirect URL https://<host>/oauth2/callback)."
  type        = string
}

variable "upstream" {
  description = "URL of the protected application inside the cluster."
  type        = string
}

variable "oidc" {
  description = "Keycloak client. `client_secret_kv_path` holds property client-secret."
  type = object({
    issuer                = string
    client_id             = string
    client_secret_kv_path = string
  })
}

variable "allowed_groups" {
  description = "Keycloak groups (token claim `groups`) allowed to reach the upstream."
  type        = list(string)
}

variable "kv_prefix" {
  description = "OpenBao KV path prefix for the generated cookie secret."
  type        = string
}

variable "resources" {
  description = "Container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "5m", memory = "32Mi" }
    limits   = { memory = "128Mi" }
  }
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

variable "secret_stores" {
  description = "External Secrets stores for this module's secrets: { read, push, kind }. Pass module.ns_<x>.secret_stores (the namespace's own SecretStores, kv/<ns>/* + granted reads, stack 11 namespace_secret_stores); the default names are the namespace's own SecretStores."
  type = object({
    read = string
    push = string
    kind = string
  })
  default = { read = "openbao", push = "openbao-push", kind = "SecretStore" }
}
