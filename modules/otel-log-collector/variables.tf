variable "namespace" {
  description = "Namespace for the DaemonSet. Reading node log files needs hostPath volumes and uid 0, so this namespace runs with Pod Security `privileged` (documented exception) and holds nothing else."
  type        = string
}

variable "chart" {
  description = "opentelemetry-collector chart (module.versions.charts[\"opentelemetry-collector\"])."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "image" {
  description = "Collector image, k8s distribution (module.versions.images[\"otel-collector\"])."
  type = object({
    repository = string
    tag        = string
    digest     = string
  })
}

variable "loki_url" {
  description = "Loki base URL (https), OTLP endpoint is <url>/otlp."
  type        = string
}

variable "tenants" {
  description = "Loki tenants for ordinary and audit logs."
  type = object({
    platform = string
    audit    = string
  })
  default = { platform = "platform", audit = "audit" }
}

variable "audit_sources" {
  description = <<-EOT
    Container logs that belong to the audit trail. A line is audit when the
    namespace and the container name match and, if set, the body matches the
    RE2 regular expression. It is sent to the audit tenant with the attribute
    boccob.audit.source = <source>.
  EOT
  type = list(object({
    source     = string
    namespace  = string
    container  = string
    body_regex = optional(string)
  }))
  default = [
    { source = "openbao", namespace = "secrets", container = "openbao", body_regex = "\"type\":\"(request|response)\"" },
    { source = "keycloak", namespace = "identity", container = "keycloak", body_regex = "org\\.keycloak\\.events" },
    { source = "trino", namespace = "query", container = "audit-log" },
    { source = "opa", namespace = "query", container = "opa", body_regex = "decision_id" },
    { source = "polaris", namespace = "catalog", container = "polaris" },
    { source = "kyverno", namespace = "kyverno", container = "kyverno", body_regex = "\"(policy|PolicyViolation)\"" },
  ]
}

variable "kube_audit_log_path" {
  description = "Kubernetes API audit log on the server nodes (null = not collected, e.g. agents only)."
  type        = string
  default     = "/var/log/kubernetes/audit/audit.log"
}

variable "start_at" {
  description = "Where to start reading files the collector has not seen yet (end | beginning)."
  type        = string
  default     = "end"
}

variable "resources" {
  description = "Collector container resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "20m", memory = "64Mi" }
    limits   = { memory = "256Mi" }
  }
}

variable "ca_configmap" {
  description = "ConfigMap with the platform CA bundle (key ca.crt) to verify Loki."
  type        = string
  default     = "platform-ca"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
