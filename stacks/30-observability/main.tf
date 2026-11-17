# 30-observability: metrics, logs and the audit trail.
#   observability        Prometheus + Alertmanager, Loki (S3 platform-logs), Grafana
#   observability-agent  OpenTelemetry log collector (DaemonSet; privileged PSS:
#                        hostPath read of node log files, see modules/otel-log-collector)
# Audit logs (Kubernetes API, OpenBao, Keycloak events, Trino, OPA, Polaris,
# Kyverno) go to the Loki tenant `audit` with its own retention; only the
# Grafana organisation `Audit` (Keycloak group auditor) has a data source for it.

data "kubernetes_config_map_v1" "platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = local.platform.namespaces.platform
  }
}

locals {
  ns        = local.platform.namespaces
  ns_agent  = "observability-agent"
  ca_pem    = data.kubernetes_config_map_v1.platform_ca.data["ca.crt"]
  s3_port   = tonumber(split(":", local.platform.s3_url)[2])
  loki_host = "loki.${local.ns.observability}.svc"

  # pod scrape jobs: every entry needs an ingress opening in the target namespace
  scrape_jobs = {
    "cloudnative-pg-instances" = { namespace = local.ns.database, port = 9187 }
    "cert-manager"             = { namespace = local.ns.platform, port = 9402 }
    "platform-controllers"     = { namespace = local.ns.platform, port = 8080 } # External Secrets, CloudNativePG operator
    "kyverno"                  = { namespace = "kyverno", port = 8000 }
    "traefik"                  = { namespace = "kube-system", port = 9100 }
    "coredns"                  = { namespace = "kube-system", port = 9153 }
    "otel-log-collector"       = { namespace = local.ns_agent, port = 8888 }
    "loki"                     = { namespace = local.ns.observability, port = 3100, scheme = "https", server_name = local.loki_host }
  }
  static_jobs = {
    "openbao" = {
      target      = "openbao.${local.ns.secrets}.svc:8200"
      path        = "/v1/sys/metrics"
      params      = { format = ["prometheus"] }
      server_name = "openbao.${local.ns.secrets}.svc"
    }
  }

  alert_rules = [
    {
      name = "platform-health"
      rules = [
        { alert = "TargetDown", expr = "up == 0", for = "10m", labels = { severity = "warning" },
        annotations = { summary = "{{ $labels.job }} target {{ $labels.instance }} is down" } },
        { alert = "PrometheusRuleFailures", expr = "increase(prometheus_rule_evaluation_failures_total[10m]) > 0", for = "10m", labels = { severity = "warning" },
        annotations = { summary = "Prometheus rule evaluation failures" } },
        { alert = "PersistentVolumeFillingUp", expr = "kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.10", for = "15m", labels = { severity = "warning" },
        annotations = { summary = "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} has less than 10% free" } },
        { alert = "PostgreSQLDown", expr = "cnpg_collector_up == 0", for = "5m", labels = { severity = "critical" },
        annotations = { summary = "PostgreSQL instance {{ $labels.pod }} is down" } },
        { alert = "LogPipelineDropping", expr = "rate(otelcol_exporter_send_failed_log_records_total[10m]) > 0", for = "15m", labels = { severity = "warning" },
        annotations = { summary = "Log collector cannot deliver logs to Loki (audit trail incomplete)" } },
      ]
    },
    {
      name = "security"
      rules = [
        { alert = "OpenBaoSealed", expr = "vault_core_unsealed == 0", for = "1m", labels = { severity = "critical" },
        annotations = { summary = "OpenBao is sealed: secrets, PKI and External Secrets are unavailable until custodians unseal it" } },
        { alert = "OpenBaoMetricsMissing", expr = "absent(vault_core_unsealed)", for = "10m", labels = { severity = "critical" },
        annotations = { summary = "No metrics from OpenBao (down or unreachable)" } },
        { alert = "CertificateExpiringSoon", expr = "certmanager_certificate_expiration_timestamp_seconds - time() < ${var.cert_expiry_warning_days} * 86400", for = "1h", labels = { severity = "warning" },
        annotations = { summary = "Certificate {{ $labels.namespace }}/{{ $labels.name }} expires in less than ${var.cert_expiry_warning_days} days (renewal failing?)" } },
        { alert = "CertificateNotReady", expr = "certmanager_certificate_ready_status{condition=\"False\"} == 1", for = "15m", labels = { severity = "warning" },
        annotations = { summary = "Certificate {{ $labels.namespace }}/{{ $labels.name }} is not ready" } },
        { alert = "KyvernoPolicyFailures", expr = "sum by (policy_name) (increase(kyverno_policy_results_total{rule_result=\"fail\"}[1h])) > 0", for = "0m", labels = { severity = "info" },
        annotations = { summary = "Kyverno policy {{ $labels.policy_name }} reported failures in the last hour (kubectl get policyreport -A)" } },
      ]
    },
    {
      name = "backup"
      rules = [
        { alert = "PostgreSQLBackupFailed", expr = "cnpg_collector_last_failed_backup_timestamp > cnpg_collector_last_available_backup_timestamp", for = "5m", labels = { severity = "critical" },
        annotations = { summary = "Last base backup of {{ $labels.pod }} failed" } },
        { alert = "PostgreSQLBackupTooOld", expr = "time() - cnpg_collector_last_available_backup_timestamp > ${var.backup_max_age_hours} * 3600 and cnpg_collector_last_available_backup_timestamp > 0", for = "15m", labels = { severity = "critical" },
        annotations = { summary = "Newest base backup of {{ $labels.pod }} is older than ${var.backup_max_age_hours}h" } },
        { alert = "PostgreSQLWALArchivingStalled", expr = "cnpg_pg_stat_archiver_seconds_since_last_archival > ${var.wal_archive_max_age_minutes} * 60", for = "10m", labels = { severity = "critical" },
        annotations = { summary = "{{ $labels.pod }}: no WAL archived for ${var.wal_archive_max_age_minutes} min (RPO at risk)" } },
        { alert = "PostgreSQLWALArchivingFailing", expr = "increase(cnpg_pg_stat_archiver_failed_count[15m]) > 0", for = "15m", labels = { severity = "critical" },
        annotations = { summary = "{{ $labels.pod }}: WAL archiving to object storage fails" } },
        { alert = "BackupJobFailed", expr = "kube_job_status_failed{namespace=\"backup\"} > 0", for = "5m", labels = { severity = "critical" },
        annotations = { summary = "Backup job {{ $labels.job_name }} failed (needs kube-state-metrics)" } },
        { alert = "OpenBaoSnapshotTooOld", expr = "time() - kube_cronjob_status_last_successful_time{namespace=\"backup\",cronjob=\"openbao-snapshot\"} > 2 * 3600", for = "15m", labels = { severity = "critical" },
        annotations = { summary = "No successful OpenBao snapshot for 2h (needs kube-state-metrics)" } },
      ]
    },
  ]
}

# =============================================================================
# Namespaces
# =============================================================================
module "ns_observability" {
  source = "../../modules/namespace-baseline"
  name   = local.ns.observability
  labels = local.common_labels

  allow_kube_api           = true # Prometheus service discovery
  secrets_access           = true
  ca_bundle_pem            = local.ca_pem
  allow_ingress_hosts      = true # Grafana -> Keycloak issuer
  ingress_controller_ports = [3000]
  ingress_rules = [
    { name = "log-push", from_namespaces = [local.ns_agent], ports = [3100] },
  ]
  egress_rules = [
    { name = "s3", to_namespaces = [local.ns.storage], ports = [local.s3_port] },
    { name = "metrics-database", to_namespaces = [local.ns.database], ports = [9187] },
    { name = "metrics-platform", to_namespaces = [local.ns.platform], ports = [9402, 8080] },
    { name = "metrics-openbao", to_namespaces = [local.ns.secrets], ports = [8200] },
    { name = "metrics-kyverno", to_namespaces = ["kyverno"], ports = [8000] },
    { name = "metrics-kube-system", to_namespaces = ["kube-system"], ports = [9100, 9153] },
    { name = "metrics-agent", to_namespaces = [local.ns_agent], ports = [8888] },
    # kubelet /metrics and /metrics/cadvisor on the nodes (node network in cluster_cidrs)
    { name = "metrics-kubelet", to_cidrs = var.cluster_cidrs, ports = [10250] },
  ]
  resource_quota = {
    "requests.memory" = "3Gi"
    "limits.memory"   = "6Gi"
    "pods"            = "20"
  }
}

module "ns_agent" {
  source = "../../modules/namespace-baseline"
  name   = local.ns_agent
  labels = local.common_labels
  # hostPath (read-only) on /var/log/pods and the API audit log, uid 0 without
  # capabilities: not possible under baseline/restricted. Nothing else runs here.
  pod_security_level = "privileged"
  ca_bundle_pem      = local.ca_pem
  ingress_rules = [
    { name = "metrics", from_namespaces = [local.ns.observability], ports = [8888] },
  ]
  egress_rules = [
    { name = "loki", to_namespaces = [local.ns.observability], ports = [3100] },
  ]
}

# =============================================================================
# Loki (logs + audit trail on S3 platform-logs)
# =============================================================================
module "logs_s3_credentials" {
  source    = "../../modules/external-secret"
  name      = "platform-logs-s3"
  namespace = module.ns_observability.name
  kv_path   = "storage/s3-users/platform-logs"
  template = {
    access_key_id     = "{{ index . \"access-key\" }}"
    secret_access_key = "{{ index . \"secret-key\" }}"
  }
  labels = local.common_labels
}

module "loki" {
  source    = "../../modules/loki"
  namespace = module.ns_observability.name
  chart     = module.versions.charts["loki"]
  image     = module.versions.images["loki"]
  s3 = {
    endpoint           = local.platform.s3_url
    bucket             = "platform-logs"
    credentials_secret = module.logs_s3_credentials.secret_name
    region             = local.platform.s3_region
  }
  tenants = {
    platform = { retention_period = var.log_retention_period }
    audit    = { retention_period = var.audit_retention_period }
  }
  default_retention_period = var.log_retention_period
  replicas                 = var.loki_replicas
  storage_size             = var.loki_storage_size
  resources                = coalesce(var.loki_resources, { requests = { cpu = "50m", memory = "192Mi" }, limits = { memory = "768Mi" } })
  cluster_issuer           = local.platform.cluster_issuer
  labels                   = local.common_labels
}

module "log_collector" {
  count     = var.log_collector_enabled ? 1 : 0
  source    = "../../modules/otel-log-collector"
  namespace = module.ns_agent.name
  chart     = module.versions.charts["opentelemetry-collector"]
  image     = module.versions.images["otel-collector"]
  loki_url  = module.loki.url
  audit_sources = coalesce(var.audit_sources, [
    { source = "openbao", namespace = local.ns.secrets, container = "openbao", body_regex = "\"type\":\"(request|response)\"" },
    { source = "keycloak", namespace = local.ns.identity, container = "keycloak", body_regex = "org\\.keycloak\\.events" },
    { source = "trino", namespace = local.ns.query, container = "audit-log", body_regex = null },
    { source = "opa", namespace = local.ns.query, container = "opa", body_regex = "decision_id" },
    { source = "polaris", namespace = local.ns.catalog, container = "polaris", body_regex = null },
    { source = "kyverno", namespace = "kyverno", container = "kyverno", body_regex = "\"(policy|PolicyViolation)\"" },
  ])
  labels = local.common_labels
}

# =============================================================================
# Prometheus + Alertmanager
# =============================================================================
module "prometheus" {
  source    = "../../modules/prometheus"
  namespace = module.ns_observability.name
  chart     = module.versions.charts["prometheus"]
  images = {
    prometheus      = module.versions.images["prometheus"]
    config_reloader = module.versions.images["prometheus-config-reloader"]
    alertmanager    = module.versions.images["alertmanager"]
  }
  replicas                   = var.ha ? 2 : 1
  retention                  = var.metrics_retention
  retention_size             = var.metrics_retention_size
  storage_size               = var.prometheus_storage_size
  resources                  = coalesce(var.prometheus_resources, { requests = { cpu = "50m", memory = "256Mi" }, limits = { memory = "768Mi" } })
  alertmanager               = { replicas = var.ha ? 2 : 1, persistence = var.ha, config = var.alertmanager_config }
  kube_state_metrics_enabled = var.kube_state_metrics_enabled
  kube_state_metrics_image   = var.kube_state_metrics_enabled ? lookup(module.versions.images, "kube-state-metrics", null) : null
  scrape_jobs                = local.scrape_jobs
  static_jobs                = local.static_jobs
  alert_rules                = local.alert_rules
  labels                     = local.common_labels
}

# =============================================================================
# WORM archive of the audit trail (bucket platform-audit, object lock, stack 12)
# =============================================================================
module "audit_archive" {
  count     = var.audit_archive_enabled ? 1 : 0
  source    = "../../modules/audit-archive"
  namespace = module.ns_observability.name
  images = {
    python = module.versions.images["python"].ref
    rc     = module.versions.images["rustfs-rc"].ref
  }
  schedule = var.audit_archive_schedule
  loki_url = module.loki.url
  s3 = {
    endpoint           = local.platform.s3_url
    bucket             = "platform-audit"
    credentials_secret = module.logs_s3_credentials.secret_name
  }
  labels = local.common_labels
}
