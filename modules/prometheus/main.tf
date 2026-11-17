# Prometheus server + Alertmanager (prometheus-community chart). Explicit scrape
# jobs (no annotation-based discovery): every target is a decision, and every
# job needs a matching NetworkPolicy opening in the target namespace.

locals {
  ca_file = "/etc/platform-ca/ca.crt"
  security_context = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    runAsNonRoot             = true
    capabilities             = { drop = ["ALL"] }
  }
  pod_jobs = [for name, j in var.scrape_jobs : merge(
    {
      job_name              = name
      scheme                = j.scheme
      metrics_path          = j.path
      kubernetes_sd_configs = [{ role = "pod", namespaces = { names = [j.namespace] } }]
      relabel_configs = [
        { source_labels = ["__meta_kubernetes_pod_container_port_number"], regex = tostring(j.port), action = "keep" },
        { source_labels = ["__meta_kubernetes_pod_phase"], regex = "Running", action = "keep" },
        { source_labels = ["__meta_kubernetes_namespace"], target_label = "namespace" },
        { source_labels = ["__meta_kubernetes_pod_name"], target_label = "pod" },
        { source_labels = ["__meta_kubernetes_pod_container_name"], target_label = "container" },
      ]
    },
    j.scheme == "https" ? { tls_config = merge({ ca_file = local.ca_file }, j.server_name == null ? {} : { server_name = j.server_name }) } : {},
  )]
  static = [for name, j in var.static_jobs : merge(
    {
      job_name       = name
      scheme         = j.scheme
      metrics_path   = j.path
      params         = j.params
      static_configs = [{ targets = [j.target] }]
    },
    j.scheme == "https" ? { tls_config = merge({ ca_file = local.ca_file }, j.server_name == null ? {} : { server_name = j.server_name }) } : {},
  )]
  image = { for k, v in var.images : k => { repository = v.repository, tag = v.tag, digest = v.digest } }
}

resource "helm_release" "this" {
  name       = "prometheus"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    configmapReload = { prometheus = { image = local.image["config_reloader"], containerSecurityContext = local.security_context } }
    server = {
      image         = local.image["prometheus"]
      replicaCount  = var.replicas
      statefulSet   = { enabled = var.replicas > 1 }
      retention     = var.retention
      retentionSize = var.retention_size
      resources     = var.resources
      persistentVolume = merge(
        { enabled = true, size = var.storage_size },
        var.storage_class == null ? {} : { storageClass = var.storage_class },
      )
      securityContext          = { runAsUser = 65534, runAsGroup = 65534, fsGroup = 65534, runAsNonRoot = true, seccompProfile = { type = "RuntimeDefault" } }
      containerSecurityContext = local.security_context
      extraConfigmapMounts     = [{ name = "platform-ca", mountPath = "/etc/platform-ca", configMap = var.ca_configmap, readOnly = true }]
      podDisruptionBudget      = { enabled = var.replicas > 1, maxUnavailable = 1 }
      global                   = { scrape_interval = "30s", evaluation_interval = "30s" }
    }
    scrapeConfigs = {
      "kubernetes-service-endpoints"      = { enabled = false }
      "kubernetes-service-endpoints-slow" = { enabled = false }
      "prometheus-pushgateway"            = { enabled = false }
      "kubernetes-services"               = { enabled = false }
      "kubernetes-pods"                   = { enabled = false }
      "kubernetes-pods-slow"              = { enabled = false }
    }
    extraScrapeConfigs = yamlencode(concat(local.pod_jobs, local.static))
    serverFiles = {
      "alerting_rules.yml" = { groups = var.alert_rules }
    }
    alertmanager = {
      enabled      = var.alertmanager.enabled
      replicaCount = var.alertmanager.replicas
      image        = { repository = var.images["alertmanager"].repository, tag = "${var.images["alertmanager"].tag}@${var.images["alertmanager"].digest}" }
      configmapReload = {
        enabled = true
        image   = { repository = var.images["config_reloader"].repository, tag = "${var.images["config_reloader"].tag}@${var.images["config_reloader"].digest}" }
      }
      persistence        = { enabled = var.alertmanager.persistence }
      resources          = var.alertmanager.resources
      podSecurityContext = { runAsUser = 65534, runAsGroup = 65534, fsGroup = 65534, runAsNonRoot = true, seccompProfile = { type = "RuntimeDefault" } }
      securityContext    = local.security_context
      config = var.alertmanager.config != null ? var.alertmanager.config : {
        global    = {}
        route     = { receiver = "default", group_by = ["alertname", "namespace"], group_wait = "30s", group_interval = "5m", repeat_interval = "4h" }
        receivers = [{ name = "default" }]
      }
    }
    "kube-state-metrics" = merge(
      { enabled = var.kube_state_metrics_enabled },
      var.kube_state_metrics_enabled ? {
        image = {
          registry   = var.kube_state_metrics_image.registry
          repository = var.kube_state_metrics_image.repository_path
          tag        = var.kube_state_metrics_image.tag_digest
        }
      } : {},
    )
    "prometheus-node-exporter" = { enabled = false }
    "prometheus-pushgateway"   = { enabled = false }
  })]
}
