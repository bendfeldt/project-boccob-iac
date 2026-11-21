variable "name" {
  description = "Release name (also Service, certificate and hostname prefix), e.g. grafana or grafana-audit."
  type        = string
  default     = "grafana"
}

variable "namespace" {
  description = "Namespace (baseline with allow_ingress_hosts for the OIDC issuer, ingress_controller_ports [3000], secrets_access)."
  type        = string
}

variable "chart" {
  description = "grafana chart (module.versions.charts[\"grafana\"])."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "image" {
  description = "Grafana image (module.versions.images[\"grafana\"])."
  type = object({
    registry        = string
    repository_path = string
    tag_digest      = string
  })
}

variable "public_port" {
  description = "\":<port>\" when the public URLs use a non-default https port, else \"\"."
  type        = string
  default     = ""
}

variable "hostname" {
  description = "Public hostname (grafana.<base_domain>); the OIDC redirect URI is https://<hostname>/login/generic_oauth."
  type        = string
}

variable "oidc" {
  description = "OIDC: issuer URL, client id, and the Secret (in this namespace) holding client-secret (synced from kv/identity/oidc-clients/<client>)."
  type = object({
    issuer        = string
    client_id     = string
    client_secret = string
  })
}

variable "role_mapping" {
  description = <<-EOT
    Keycloak groups (token claim `groups`) -> Grafana role. strict = true denies
    login to everyone who matches no group (used for the audit instance).
  EOT
  type = object({
    admin_groups  = optional(list(string), [])
    editor_groups = optional(list(string), [])
    viewer_groups = optional(list(string), [])
    strict        = optional(bool, false)
  })
}

variable "datasources" {
  description = "Provisioned data sources (Grafana datasource provisioning list). Loki tenants are selected with httpHeaderName1 = X-Scope-OrgID."
  type        = any
  default     = []
}

variable "dashboards" {
  description = "Provisioned dashboards: name => dashboard JSON (string)."
  type        = map(string)
  default     = {}
}

variable "replicas" {
  description = "Grafana replicas (> 1 needs a shared database; dev/test single replica with SQLite)."
  type        = number
  default     = 1
}

variable "resources" {
  description = "Grafana resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "128Mi" }
    limits   = { memory = "384Mi" }
  }
}

variable "cluster_issuer" {
  description = "ClusterIssuer of the HTTPS certificate (Grafana serves TLS itself; Traefik verifies it)."
  type        = string
  default     = "openbao-pki"
}

variable "ca_configmap" {
  description = "ConfigMap with the platform CA bundle (OIDC issuer, Loki, Prometheus TLS)."
  type        = string
  default     = "platform-ca"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
