variable "namespace" {
  description = "Namespace (convention: identity; needs secrets_access = true and the platform-ca ConfigMap)."
  type        = string
}

variable "image" {
  description = "Full Keycloak image reference (module.versions.images[\"keycloak\"].ref)."
  type        = string
}

variable "replicas" {
  description = "Keycloak pods. >1 forms an Infinispan cluster (jdbc-ping over the shared database)."
  type        = number
  default     = 1
}

variable "hostname" {
  description = "Public hostname (https://<hostname> is the fixed frontend and issuer URL)."
  type        = string
}

variable "database" {
  description = "PostgreSQL connection. `secret` is a Secret in this namespace with keys username / password."
  type = object({
    host   = string
    port   = optional(number, 5432)
    name   = string
    secret = string
  })
}

variable "realm" {
  description = "Realm to create and manage."
  type        = string
  default     = "lakehouse"
}

variable "realm_roles" {
  description = "Realm roles (name => description). A group with the same name is created and mapped to the role, so membership is managed through groups."
  type        = map(string)
  default = {
    "platform-admin" = "Operates the platform: full administrative access"
    "data-engineer"  = "Builds and runs pipelines: read/write on all data layers, no PII in clear text"
    "analyst"        = "Reads curated (and consolidated) data, PII masked"
    "pii-reader"     = "May see PII columns unmasked (granted in addition to another role)"
    "auditor"        = "Read-only access to audit logs and configuration"
  }
}

variable "oidc_clients" {
  description = <<-EOT
    Confidential OIDC clients (client id => settings). The client secret is
    generated in-cluster and stored in OpenBao at
    kv/identity/oidc-clients/<client id> (properties client-id, client-secret, issuer).
  EOT
  type = map(object({
    name                  = optional(string)
    redirect_uris         = optional(list(string), [])
    web_origins           = optional(list(string), ["+"])
    standard_flow         = optional(bool, true)
    service_account       = optional(bool, false)
    direct_access_grants  = optional(bool, false)
    pkce_required         = optional(bool, false)
    service_account_roles = optional(list(string), [])
    # client roles of other clients for the service account, e.g. { "realm-management" = ["view-users"] }
    service_account_client_roles = optional(map(list(string)), {})
    # replaces the realm's default optional client scopes for this client, e.g. ["kc-admin-api"] for Admin REST API callers
    optional_client_scopes = optional(list(string))
  }))
  default = {}
}

variable "resources" {
  description = "Keycloak container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "100m", memory = "640Mi" }
    limits   = { memory = "1280Mi" }
  }
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer for the pod certificate."
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
  description = "External Secrets stores used for the generated credentials: { read, push, kind }. Default = legacy ClusterSecretStores; pass module.ns_x.secret_stores for the namespace's own SecretStores."
  type = object({
    read = string
    push = string
    kind = string
  })
  default = { read = "openbao", push = "openbao-push", kind = "ClusterSecretStore" }
}
