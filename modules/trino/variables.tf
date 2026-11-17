variable "namespace" {
  description = "Namespace (convention: query; needs secrets_access = true and the platform-ca ConfigMap)."
  type        = string
}

variable "chart" {
  description = "Trino chart (module.versions.charts[\"trino\"])."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "images" {
  description = "Images from module.versions.images: trino, python (group sync and audit sidecars), jmx_exporter."
  type        = map(any)
}

variable "environment" {
  description = "Value of node.environment (letters, digits, underscore)."
  type        = string
}

# --- topology / sizing ---------------------------------------------------------
variable "workers" {
  description = "Worker pods. 0 = the coordinator also executes queries (dev)."
  type        = number
  default     = 0
}

variable "worker_autoscaling" {
  description = "Autoscale workers between `workers` and `max_replicas`: HPA on CPU/memory, or KEDA when `keda_triggers` is set (KEDA must be installed)."
  type = object({
    enabled                    = optional(bool, false)
    max_replicas               = optional(number, 5)
    target_cpu_utilization     = optional(number, 60)
    target_memory_utilization  = optional(number, 80)
    scale_down_stabilization_s = optional(number, 600)
    keda_triggers              = optional(any, [])
  })
  default = {}
}

variable "coordinator" {
  description = "Coordinator sizing. Query memory limits must fit into the heap (30 % headroom is reserved by Trino)."
  type = object({
    heap                      = optional(string, "1792M")
    query_max_memory          = optional(string, "800MB")
    query_max_memory_per_node = optional(string, "800MB")
    resources = optional(object({ requests = map(string), limits = map(string) }), {
      requests = { cpu = "200m", memory = "2304Mi" }
      limits   = { memory = "2816Mi" }
    })
  })
  default = {}
}

variable "worker" {
  description = "Worker sizing and graceful shutdown grace period (the pod waits 2 x grace period before it stops)."
  type = object({
    heap                      = optional(string, "8G")
    query_max_memory_per_node = optional(string, "4GB")
    graceful_shutdown_seconds = optional(number, 120)
    resources = optional(object({ requests = map(string), limits = map(string) }), {
      requests = { cpu = "2", memory = "10Gi" }
      limits   = { memory = "10Gi" }
    })
  })
  default = {}
}

# --- catalogs ---------------------------------------------------------------------
variable "catalogs" {
  description = "Iceberg REST catalogs: Trino catalog name => Polaris catalog (warehouse)."
  type        = map(string)
}

variable "polaris" {
  description = "Polaris REST endpoint and the OpenBao KV path with the principal credentials (property `credential` = id:secret)."
  type = object({
    uri                 = string
    credentials_kv_path = string
    scope               = optional(string, "PRINCIPAL_ROLE:ALL")
  })
}

variable "s3" {
  description = "Object storage. `credentials_kv_path`: OpenBao KV path with access-key / secret-key."
  type = object({
    endpoint            = string
    region              = string
    credentials_kv_path = string
  })
}

# --- authentication -----------------------------------------------------------------
variable "oidc" {
  description = "Keycloak client for OAuth2 (web UI, CLI/JDBC external authentication, bearer tokens). `client_secret_kv_path` holds property client-secret."
  type = object({
    issuer                = string
    client_id             = string
    client_secret_kv_path = string
    principal_field       = optional(string, "preferred_username")
    additional_audiences  = optional(list(string), [])
  })
}

variable "service_accounts" {
  description = <<-EOT
    Non-human accounts authenticated with a password (PASSWORD authenticator, bcrypt
    password file). name => groups. Passwords are generated in-cluster and stored in
    OpenBao at kv/<kv_prefix>/service-accounts/<name> (username, password).
  EOT
  type = map(object({
    groups = list(string)
  }))
  default = {}
}

variable "group_sync" {
  description = "Keycloak group membership -> Trino file group provider (sidecar). `client_secret_kv_path`: service account client with realm-management roles view-users and query-groups."
  type = object({
    keycloak_url          = string
    realm                 = string
    client_id             = string
    client_secret_kv_path = string
    group_names           = optional(list(string), ["platform-admin", "data-engineer", "analyst", "pii-reader", "auditor"])
    interval_seconds      = optional(number, 30)
  })
}

# --- authorisation ------------------------------------------------------------------
variable "opa_url" {
  description = "Base URL of OPA (modules/opa output url). Policy paths are the ones of the solution's platform contract."
  type        = string
}

# --- operations ---------------------------------------------------------------------
variable "audit_full_events" {
  description = "Log complete query events instead of the audit subset (larger)."
  type        = bool
  default     = false
}

variable "resource_groups" {
  description = "Resource group limits: admin (group platform-admin), etl (service accounts svc-*), interactive (everybody else, one sub group per user)."
  type = object({
    admin_concurrency            = optional(number, 5)
    etl_concurrency              = optional(number, 12)
    etl_memory                   = optional(string, "80%")
    interactive_concurrency      = optional(number, 10)
    interactive_memory           = optional(string, "60%")
    interactive_user_concurrency = optional(number, 3)
    max_queued                   = optional(number, 200)
  })
  default = {}
}

variable "jmx_exporter" {
  description = "Prometheus JMX exporter sidecar (port 5556) on coordinator and workers."
  type        = bool
  default     = true
}

variable "service_monitor" {
  description = "Create ServiceMonitors (needs the Prometheus operator CRDs from the ops stack)."
  type        = bool
  default     = false
}

variable "kv_prefix" {
  description = "OpenBao KV v2 path prefix (without mount) for secrets generated by this module."
  type        = string
  default     = "query/trino"
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

variable "ca_bundle_pem" {
  description = "PEM content of the platform CA bundle (for the JVM trust store)."
  type        = string
}

variable "extra_config_properties" {
  description = "Extra lines for config.properties (coordinator and workers)."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
