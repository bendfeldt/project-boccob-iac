locals {
  name     = "openbao"
  tls_name = "openbao-server-tls"
  members  = [for i in range(var.replicas) : "${local.name}-${i}"]

  config = <<-HCL
    ui = true

    listener "tcp" {
      address         = "[::]:8200"
      cluster_address = "[::]:8201"
      tls_cert_file   = "/openbao/tls/tls.crt"
      tls_key_file    = "/openbao/tls/tls.key"
      tls_min_version = "tls12"
      # Prometheus scrapes /v1/sys/metrics without a token (no secret in the
      # scrape config / tofu state); metrics carry no secret values and the
      # port is limited by NetworkPolicy to the OpenBao client namespaces.
      telemetry {
        unauthenticated_metrics_access = true
      }
    }

    storage "raft" {
      path = "/openbao/data"
    %{for member in local.members~}
      retry_join {
        leader_api_addr       = "https://${member}.${local.name}-internal:8200"
        leader_ca_cert_file   = "/openbao/tls/ca.crt"
        leader_tls_servername = "${local.name}.${var.namespace}.svc"
      }
    %{endfor~}
    }

    service_registration "kubernetes" {}

    # Audit devices are declared here (not through the API) so they cannot be
    # disabled with a token and are identical on every member.
    audit "file" "stdout" {
      description = "audit log to stdout (shipped by the log pipeline)"
      options {
        file_path = "stdout"
      }
    }
    audit "file" "file" {
      description = "audit log on the dedicated audit volume"
      options {
        file_path = "/openbao/audit/audit.log"
      }
    }

    telemetry {
      prometheus_retention_time = "30s"
      disable_hostname          = true
    }
  HCL
}

# Listener certificate from the bootstrap CA: OpenBao must be able to start and
# be unsealed before its own PKI engine exists.
resource "kubernetes_manifest" "server_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.tls_name
      namespace = var.namespace
    }
    spec = {
      secretName  = local.tls_name
      commonName  = "${local.name}.${var.namespace}.svc"
      duration    = "2160h0m0s"
      renewBefore = "720h0m0s"
      privateKey  = { algorithm = "ECDSA", size = 256, rotationPolicy = "Always" }
      usages      = ["server auth", "client auth"]
      dnsNames = [
        local.name,
        "${local.name}.${var.namespace}",
        "${local.name}.${var.namespace}.svc",
        "${local.name}.${var.namespace}.svc.cluster.local",
        "${local.name}-active.${var.namespace}.svc",
        "${local.name}-standby.${var.namespace}.svc",
        "*.${local.name}-internal",
        "*.${local.name}-internal.${var.namespace}.svc",
        "*.${local.name}-internal.${var.namespace}.svc.cluster.local",
        "localhost",
      ]
      ipAddresses = ["127.0.0.1"]
      issuerRef   = { group = "cert-manager.io", kind = "ClusterIssuer", name = var.tls_issuer }
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
  # pods only become Ready after init/unseal (scripts/openbao/init.sh)
  wait = false

  values = [yamlencode({
    global   = { tlsDisable = false }
    injector = { enabled = false }
    ui       = { enabled = false }
    server = {
      image = {
        registry   = var.image.registry
        repository = var.image.repository_path
        tag        = var.image.tag_digest
      }
      logLevel           = var.log_level
      logFormat          = "json"
      resources          = var.resources
      updateStrategyType = "OnDelete"
      authDelegator      = { enabled = true }
      extraEnvironmentVars = {
        BAO_CACERT = "/openbao/tls/ca.crt"
      }
      volumes = [
        { name = "tls", secret = { secretName = local.tls_name } },
        # the chart renders the final config into /tmp (rootfs is read-only)
        { name = "tmp", emptyDir = { medium = "Memory", sizeLimit = "16Mi" } },
      ]
      volumeMounts = [
        { name = "tls", mountPath = "/openbao/tls", readOnly = true },
        { name = "tmp", mountPath = "/tmp" },
      ]
      statefulSet = {
        securityContext = {
          container = {
            allowPrivilegeEscalation = false
            readOnlyRootFilesystem   = true
            capabilities             = { drop = ["ALL"] }
          }
        }
      }
      dataStorage  = { enabled = true, size = var.data_storage_size, storageClass = var.storage_class }
      auditStorage = { enabled = true, size = var.audit_storage_size, storageClass = var.storage_class }
      standalone   = { enabled = false }
      ha = {
        enabled  = true
        replicas = var.replicas
        raft = {
          enabled   = true
          setNodeId = true
          config    = local.config
        }
        disruptionBudget = { enabled = var.replicas > 1 }
      }
    }
  })]

  depends_on = [kubernetes_manifest.server_cert]
}
