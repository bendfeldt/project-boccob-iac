# Common variables come from _common.tf.

variable "layers" {
  description = "Data layers: one Trino catalog per Polaris catalog of the same name."
  type        = list(string)
  default     = ["raw", "clean", "consolidated", "curated"]
}

# --- OPA ------------------------------------------------------------------------------
variable "opa_bundle_ref" {
  description = "Digest-pinned OCI reference of the solution's OPA policy bundle (dist/opa/bundle.ref of the solution repository)."
  type        = string
}

variable "registry_ca_pem" {
  description = "CA of the Zot registry (set by scripts/tofu.sh from ~/.boccob/<env>/pki/registry-ca.crt)."
  type        = string
  default     = null
}

variable "registry_cidrs" {
  description = "Addresses of the Zot registry (egress of the OPA pods)."
  type        = list(string)
}

variable "opa_replicas" {
  description = "OPA pods (null = 1, or 2 with ha=true)."
  type        = number
  default     = null
}

# --- Trino ------------------------------------------------------------------------------
variable "trino_workers" {
  description = "Trino workers (null = 0 (coordinator executes queries), or 2 with ha=true). Minimum when autoscaling."
  type        = number
  default     = null
}

variable "trino_worker_autoscaling" {
  description = "Worker autoscaling (see modules/trino variable worker_autoscaling)."
  type        = any
  default     = {}
}

variable "trino_coordinator" {
  description = "Coordinator sizing (see modules/trino variable coordinator)."
  type        = any
  default     = {}
}

variable "trino_worker" {
  description = "Worker sizing (see modules/trino variable worker)."
  type        = any
  default     = {}
}

variable "trino_service_accounts" {
  description = "Password-authenticated service accounts and their Trino groups. Passwords: kv/query/trino/service-accounts/<name>."
  type = map(object({
    groups = list(string)
  }))
  default = {
    # Dagster / dbt (platform contract 1.2): pii-reader to transform clear values,
    # lakehouse-service to write curated.keystore / curated.audit / raw.governance
    # and lower the snapshot retention floor. lakehouse-service exists only here:
    # it is not a Keycloak group and not in the group sync's group_names, so no
    # person can obtain it through Keycloak.
    "svc-dagster" = { groups = ["data-engineer", "pii-reader", "lakehouse-service"] }
  }
}

variable "trino_s3_user" {
  description = "S3 user (stack 12) Trino uses for data files."
  type        = string
  default     = "lakehouse-query"
}

variable "trino_jmx_exporter" {
  description = "JMX exporter sidecar."
  type        = bool
  default     = true
}

variable "trino_client_namespaces" {
  description = "Namespaces whose pods may connect to the Trino coordinator (8443) directly, bypassing Traefik. Empty (default): every client uses https://trino.<base_domain>, so X-Forwarded-For in the audit trail can only come from Traefik. Pods of a listed namespace could forge it."
  type        = list(string)
  default     = []
}

variable "metrics_namespaces" {
  description = "Namespaces allowed to scrape Trino (5556) and OPA (8282) metrics."
  type        = list(string)
  default     = ["observability"]
}

variable "service_monitors" {
  description = "Create ServiceMonitors (needs the Prometheus operator CRDs from the ops stack)."
  type        = bool
  default     = false
}

variable "query_resource_quota" {
  description = "ResourceQuota of the query namespace."
  type        = map(string)
  default = {
    "requests.memory" = "6Gi"
    "limits.memory"   = "10Gi"
    "pods"            = "20"
  }
}
