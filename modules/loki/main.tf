# Loki in single-binary mode on S3 (RustFS), multi-tenant:
#   tenant `platform` = ordinary logs, tenant `audit` = audit trail with its own
#   (longer) retention. Clients authenticate tenants with X-Scope-OrgID; Loki
#   has no own authentication, so access is limited by NetworkPolicy (only the
#   collector and Grafana reach port 3100) and by Grafana data source scoping.
# HTTPS with a certificate from the platform PKI.

locals {
  name     = "loki"
  host     = "${local.name}.${var.namespace}.svc"
  tls_name = "${local.name}-server-tls"
  overrides = { for tenant, cfg in var.tenants : tenant => {
    retention_period = cfg.retention_period
  } }
  security_context = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    runAsNonRoot             = true
    capabilities             = { drop = ["ALL"] }
    seccompProfile           = { type = "RuntimeDefault" }
  }
}

resource "kubernetes_manifest" "server_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.tls_name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      secretName  = local.tls_name
      commonName  = local.host
      dnsNames    = [local.host, "${local.host}.cluster.local", "${local.name}-headless.${var.namespace}.svc"]
      duration    = "2160h0m0s"
      renewBefore = "720h0m0s"
      privateKey  = { algorithm = "ECDSA", size = 256, rotationPolicy = "Always" }
      usages      = ["server auth"]
      issuerRef   = { group = "cert-manager.io", kind = "ClusterIssuer", name = var.cluster_issuer }
    }
  }
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  timeouts {
    create = "3m"
  }
}

resource "helm_release" "this" {
  name       = local.name
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    loki = {
      image = {
        registry   = var.image.registry
        repository = var.image.repository_path
        tag        = var.image.tag_digest
      }
      auth_enabled = true
      server = {
        http_listen_port = 3100
        grpc_listen_port = 9095
        http_tls_config = {
          cert_file = "/etc/loki/tls/tls.crt"
          key_file  = "/etc/loki/tls/tls.key"
        }
      }
      readinessProbe = {
        httpGet             = { path = "/ready", port = "http-metrics", scheme = "HTTPS" }
        initialDelaySeconds = 30
        timeoutSeconds      = 1
      }
      # the chart's default liveness probe speaks plain HTTP; the server is TLS only
      livenessProbe = {
        httpGet          = { path = "/loki/api/v1/status/buildinfo", port = "http-metrics", scheme = "HTTPS" }
        periodSeconds    = 30
        failureThreshold = 10
        timeoutSeconds   = 1
      }
      # the chart aborts start-up when memberlist cannot join its peers; a single
      # replica has none before it is ready (Loki's own default: false)
      extraMemberlistConfig = { abort_if_cluster_join_fails = false }
      commonConfig          = { replication_factor = var.replicas > 1 ? 2 : 1 }
      schemaConfig = {
        configs = [{
          from         = "2024-01-01"
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index        = { prefix = "index_", period = "24h" }
        }]
      }
      storage = {
        type        = "s3"
        bucketNames = { chunks = var.s3.bucket, ruler = var.s3.bucket }
        s3 = {
          endpoint         = var.s3.endpoint
          region           = var.s3.region
          s3ForcePathStyle = true
          accessKeyId      = "$${S3_ACCESS_KEY_ID}"
          secretAccessKey  = "$${S3_SECRET_ACCESS_KEY}"
          http_config      = { ca_file = "/etc/platform-ca/ca.crt" }
        }
      }
      limits_config = {
        retention_period              = var.default_retention_period
        reject_old_samples            = true
        reject_old_samples_max_age    = "168h"
        max_cache_freshness_per_query = "10m"
        split_queries_by_interval     = "15m"
        volume_enabled                = true
        allow_structured_metadata     = true
      }
      runtimeConfig = { overrides = local.overrides }
      compactor = {
        retention_enabled    = true
        delete_request_store = "s3"
        working_directory    = "/var/loki/compactor"
      }
      pattern_ingester = { enabled = false }
      ui               = { enabled = false }
      analytics        = { reporting_enabled = false }
      podSecurityContext = {
        runAsNonRoot   = true
        runAsUser      = 10001
        runAsGroup     = 10001
        fsGroup        = 10001
        seccompProfile = { type = "RuntimeDefault" }
      }
      containerSecurityContext = local.security_context
    }
    singleBinary = {
      replicas  = var.replicas
      extraArgs = ["-config.expand-env=true"]
      extraEnv = [
        { name = "S3_ACCESS_KEY_ID", valueFrom = { secretKeyRef = { name = var.s3.credentials_secret, key = "access_key_id" } } },
        { name = "S3_SECRET_ACCESS_KEY", valueFrom = { secretKeyRef = { name = var.s3.credentials_secret, key = "secret_access_key" } } },
      ]
      extraVolumes = [
        { name = "tls", secret = { secretName = local.tls_name } },
        { name = "platform-ca", configMap = { name = var.ca_configmap } },
      ]
      extraVolumeMounts = [
        { name = "tls", mountPath = "/etc/loki/tls", readOnly = true },
        { name = "platform-ca", mountPath = "/etc/platform-ca", readOnly = true },
      ]
      persistence = merge(
        { enabled = true, size = var.storage_size },
        var.storage_class == null ? {} : { storageClass = var.storage_class },
      )
      resources = var.resources
    }
    read              = { replicas = 0 }
    write             = { replicas = 0 }
    backend           = { replicas = 0 }
    gateway           = { enabled = false }
    chunksCache       = { enabled = false }
    resultsCache      = { enabled = false }
    lokiCanary        = { enabled = false }
    test              = { enabled = false }
    sidecar           = { rules = { enabled = false } }
    memcachedExporter = { enabled = false }
  })]

  depends_on = [kubernetes_manifest.server_cert]
}
