# OpenTelemetry Collector (k8s distribution) as a DaemonSet:
#   pod logs (/var/log/pods, CRI format) + Kubernetes API audit log
#   -> classification (audit_sources) -> routing connector
#   -> Loki OTLP, tenant `audit` for the audit trail, `platform` for the rest.
# Collector instead of Alloy: the contract names OpenTelemetry, the pinned k8s
# distribution has every component needed (checked with `components`), and the
# configuration stays vendor-neutral (any OTLP backend).

locals {
  name = "otel-log-collector"
  # OTTL string literals: JSON escaping is valid OTTL escaping
  audit_statements = [for s in var.audit_sources : join(" and ", concat(
    ["set(attributes[\"boccob.audit.source\"], ${jsonencode(s.source)}) where resource.attributes[\"k8s.namespace.name\"] == ${jsonencode(s.namespace)}",
    "resource.attributes[\"k8s.container.name\"] == ${jsonencode(s.container)}"],
    s.body_regex == null ? [] : ["IsMatch(body, ${jsonencode(s.body_regex)})"],
  ))]
  exporter = { for t, tenant in var.tenants : "otlp_http/${t}" => {
    endpoint         = "${var.loki_url}/otlp"
    headers          = { "X-Scope-OrgID" = tenant }
    tls              = { ca_file = "/etc/platform-ca/ca.crt" }
    sending_queue    = { enabled = true, queue_size = 2000 }
    retry_on_failure = { enabled = true, max_elapsed_time = "10m" }
  } }
  kube_audit = var.kube_audit_log_path != null

  config = {
    receivers = merge(
      {
        "file_log/pods" = {
          include           = ["/var/log/pods/*/*/*.log"]
          exclude           = ["/var/log/pods/${var.namespace}_*/*/*.log"]
          start_at          = var.start_at
          include_file_path = true
          include_file_name = false
          operators         = [{ type = "container", id = "container-parser" }]
        }
      },
      local.kube_audit ? {
        "file_log/kube_audit" = {
          include  = [var.kube_audit_log_path]
          start_at = var.start_at
        }
      } : {},
    )
    processors = {
      memory_limiter = { check_interval = "1s", limit_percentage = 80, spike_limit_percentage = 25 }
      "transform/classify" = {
        error_mode     = "ignore"
        log_statements = [{ context = "log", statements = local.audit_statements }]
      }
      "transform/kube_audit" = {
        error_mode = "ignore"
        log_statements = [{ context = "log", statements = [
          "set(attributes[\"boccob.audit.source\"], \"kubernetes\")",
          "set(resource.attributes[\"service.name\"], \"kube-apiserver\")",
        ] }]
      }
      batch = { send_batch_size = 1024, timeout = "5s" }
    }
    connectors = {
      routing = {
        default_pipelines = ["logs/platform"]
        error_mode        = "ignore"
        table = [{
          context   = "log"
          condition = "attributes[\"boccob.audit.source\"] != nil"
          pipelines = ["logs/audit"]
        }]
      }
    }
    exporters  = local.exporter
    extensions = { health_check = { endpoint = "$${env:MY_POD_IP}:13133" } }
    service = {
      extensions = ["health_check"]
      telemetry = {
        metrics = { readers = [{ pull = { exporter = { prometheus = { host = "$${env:MY_POD_IP}", port = 8888 } } } }] }
      }
      pipelines = merge(
        {
          "logs/in"       = { receivers = ["file_log/pods"], processors = ["memory_limiter", "transform/classify"], exporters = ["routing"] }
          "logs/platform" = { receivers = ["routing"], processors = ["batch"], exporters = ["otlp_http/platform"] }
          "logs/audit"    = { receivers = ["routing"], processors = ["batch"], exporters = ["otlp_http/audit"] }
        },
        local.kube_audit ? {
          "logs/kube_audit" = { receivers = ["file_log/kube_audit"], processors = ["memory_limiter", "transform/kube_audit", "batch"], exporters = ["otlp_http/audit"] }
        } : {},
      )
    }
  }
}

resource "helm_release" "this" {
  name       = local.name
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 300
  atomic     = true

  values = [yamlencode({
    mode            = "daemonset"
    image           = { repository = var.image.repository, tag = var.image.tag, digest = var.image.digest }
    command         = { name = "otelcol-k8s" }
    alternateConfig = local.config
    ports = {
      otlp             = { enabled = false }
      "otlp-http"      = { enabled = false }
      "jaeger-compact" = { enabled = false }
      "jaeger-thrift"  = { enabled = false }
      "jaeger-grpc"    = { enabled = false }
      zipkin           = { enabled = false }
      metrics          = { enabled = true, containerPort = 8888, servicePort = 8888, protocol = "TCP" }
    }
    service = { enabled = true }
    # node log files are root-owned (0640): uid 0, but no capabilities, no
    # privilege escalation, read-only root filesystem and read-only mounts
    podSecurityContext = { runAsUser = 0, runAsGroup = 0, seccompProfile = { type = "RuntimeDefault" } }
    securityContext = {
      runAsNonRoot             = false
      allowPrivilegeEscalation = false
      readOnlyRootFilesystem   = true
      capabilities             = { drop = ["ALL"] }
    }
    resources = var.resources
    extraVolumes = concat(
      [
        { name = "varlogpods", hostPath = { path = "/var/log/pods", type = "Directory" } },
        { name = "platform-ca", configMap = { name = var.ca_configmap } },
      ],
      local.kube_audit ? [{ name = "kube-audit", hostPath = { path = dirname(var.kube_audit_log_path), type = "DirectoryOrCreate" } }] : [],
    )
    extraVolumeMounts = concat(
      [
        { name = "varlogpods", mountPath = "/var/log/pods", readOnly = true },
        { name = "platform-ca", mountPath = "/etc/platform-ca", readOnly = true },
      ],
      local.kube_audit ? [{ name = "kube-audit", mountPath = dirname(var.kube_audit_log_path), readOnly = true }] : [],
    )
    # the API audit log only exists on server (control-plane) nodes; pods on
    # agents simply find no file
    tolerations = [{ operator = "Exists", effect = "NoSchedule" }]
  })]
}
