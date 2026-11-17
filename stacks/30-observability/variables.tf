# --- Loki / audit trail ---------------------------------------------------------------
variable "log_retention_period" {
  description = "Retention of ordinary logs (Loki tenant `platform`), Loki duration."
  type        = string
  default     = "168h"
}

variable "audit_retention_period" {
  description = "Retention of the audit trail (Loki tenant `audit`), Loki duration. Set it from the organisation's logging policy (DPO / security officer); NIS2 and ISO 27001 do not fix a number."
  type        = string
  default     = "8760h"
}

variable "loki_storage_size" {
  description = "Loki local volume (WAL, index cache)."
  type        = string
  default     = "2Gi"
}

variable "loki_replicas" {
  description = "Loki single-binary replicas."
  type        = number
  default     = 1
}

variable "loki_resources" {
  description = "Loki resources (null = module default)."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = null
}

variable "audit_sources" {
  description = "Container logs classified as audit (null = module default: OpenBao, Keycloak events, Trino audit sidecar, OPA decisions, Polaris, Kyverno). See modules/otel-log-collector."
  type        = any
  default     = null
}

variable "log_collector_enabled" {
  description = "Deploy the OpenTelemetry log collector DaemonSet."
  type        = bool
  default     = true
}

# --- Prometheus / Alertmanager -------------------------------------------------------
variable "metrics_retention" {
  description = "Prometheus TSDB retention."
  type        = string
  default     = "2d"
}

variable "metrics_retention_size" {
  description = "Prometheus TSDB size limit."
  type        = string
  default     = "800MB"
}

variable "prometheus_storage_size" {
  description = "Prometheus volume size."
  type        = string
  default     = "1Gi"
}

variable "prometheus_resources" {
  description = "Prometheus server resources (null = module default)."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = null
}

variable "alertmanager_config" {
  description = "alertmanager.yml (receivers, routes). Credentials only through *_file fields and mounted Secrets, never inline. null = a single no-op receiver (alerts visible in the Alertmanager UI/API only)."
  type        = any
  default     = null
}

variable "kube_state_metrics_enabled" {
  description = "Deploy kube-state-metrics (needs `kube-state-metrics` in versions.yaml, which is not mirrorable from the build sandbox)."
  type        = bool
  default     = false
}

variable "cert_expiry_warning_days" {
  description = "Alert when a cert-manager certificate expires in fewer days."
  type        = number
  default     = 21
}

variable "backup_max_age_hours" {
  description = "Alert when the newest PostgreSQL base backup is older (hours)."
  type        = number
  default     = 26
}

variable "wal_archive_max_age_minutes" {
  description = "Alert when no WAL segment was archived for this long (PostgreSQL RPO)."
  type        = number
  default     = 60
}

# --- Grafana -----------------------------------------------------------------------------
variable "grafana_enabled" {
  description = "Deploy Grafana (image ~480 MB; group observability-ui must be mirrored)."
  type        = bool
  default     = true
}

variable "grafana_resources" {
  description = "Grafana resources (null = module default)."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = null
}

variable "grafana_role_mapping" {
  description = "Keycloak group -> Grafana role. Members of `auditor` additionally get Viewer in the Grafana organisation `Audit`, the only place the audit log data source exists."
  type = object({
    admin_groups   = optional(list(string), ["platform-admin"])
    editor_groups  = optional(list(string), ["data-engineer"])
    auditor_groups = optional(list(string), ["auditor"])
  })
  default = {}
}

variable "audit_archive_enabled" {
  description = "Daily export of the audit tenant into the object-locked bucket platform-audit (hash-chained manifests)."
  type        = bool
  default     = true
}

variable "audit_archive_schedule" {
  description = "Cron schedule (UTC) of the audit archive (archives the previous UTC day)."
  type        = string
  default     = "20 1 * * *"
}
