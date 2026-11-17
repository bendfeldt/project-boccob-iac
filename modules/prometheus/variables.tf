variable "namespace" {
  description = "Namespace (baseline with allow_kube_api, ca_bundle_pem and egress to every scraped namespace/port)."
  type        = string
}

variable "chart" {
  description = "prometheus chart (module.versions.charts[\"prometheus\"]); includes Alertmanager as a subchart."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "images" {
  description = "Images from module.versions.images: prometheus, config_reloader, alertmanager (objects with repository, tag, digest)."
  type = map(object({
    repository = string
    tag        = string
    digest     = string
  }))
}

variable "retention" {
  description = "TSDB retention time (Prometheus duration)."
  type        = string
  default     = "2d"
}

variable "retention_size" {
  description = "TSDB size limit (e.g. 1GB); empty = none."
  type        = string
  default     = "800MB"
}

variable "storage_size" {
  description = "Prometheus volume size."
  type        = string
  default     = "1Gi"
}

variable "storage_class" {
  description = "StorageClass (null = cluster default)."
  type        = string
  default     = null
}

variable "replicas" {
  description = "Prometheus server replicas (> 1 = StatefulSet; every replica scrapes everything)."
  type        = number
  default     = 1
}

variable "resources" {
  description = "Prometheus server resources."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "256Mi" }
    limits   = { memory = "768Mi" }
  }
}

variable "alertmanager" {
  description = "Alertmanager: enabled, replicas, persistence, resources and the receivers configuration (alertmanager.yml without secrets: use *_file fields pointing at mounted Secrets for credentials)."
  type = object({
    enabled     = optional(bool, true)
    replicas    = optional(number, 1)
    persistence = optional(bool, false)
    resources = optional(object({ requests = map(string), limits = map(string) }), {
      requests = { cpu = "10m", memory = "32Mi" }
      limits   = { memory = "128Mi" }
    })
    config = optional(any, null)
  })
  default = {}
}

variable "kube_state_metrics_enabled" {
  description = "Deploy kube-state-metrics (needs its image in versions.yaml; Job/CronJob/Pod state alerts depend on it)."
  type        = bool
  default     = false
}

variable "kube_state_metrics_image" {
  description = "kube-state-metrics image (registry, repository_path, tag_digest) when enabled."
  type = object({
    registry        = string
    repository_path = string
    tag_digest      = string
  })
  default = null
}

variable "scrape_jobs" {
  description = <<-EOT
    Pod scrape jobs (kubernetes_sd role pod): name => namespace, container port,
    scheme, path, TLS server name (pod IPs are not in certificate SANs).
  EOT
  type = map(object({
    namespace   = string
    port        = number
    scheme      = optional(string, "http")
    path        = optional(string, "/metrics")
    server_name = optional(string)
  }))
  default = {}
}

variable "static_jobs" {
  description = "Static HTTPS scrape jobs: name => target host:port, path, query params, TLS server name."
  type = map(object({
    target      = string
    path        = optional(string, "/metrics")
    params      = optional(map(list(string)), {})
    scheme      = optional(string, "https")
    server_name = optional(string)
  }))
  default = {}
}

variable "alert_rules" {
  description = "Prometheus alerting rule groups (list of { name, rules }), rendered into alerting_rules.yml."
  type        = any
  default     = []
}

variable "ca_configmap" {
  description = "ConfigMap with the platform CA bundle (key ca.crt) for HTTPS targets."
  type        = string
  default     = "platform-ca"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
