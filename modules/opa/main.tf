# Open Policy Agent serving the solution's policy bundle to Trino.
# The bundle is an OCI artefact in Zot, pinned by digest; decisions are logged
# to stdout; only the configured client pods may call the API.

locals {
  host            = "${var.name}.${var.namespace}.svc"
  selector_labels = { "app.kubernetes.io/name" = var.name }
  labels          = merge(var.labels, local.selector_labels)
  registry        = split("/", var.bundle_ref)[0]
  scheme          = var.tls ? "https" : "http"

  config = yamlencode({
    services = {
      registry = merge(
        { url = "https://${local.registry}", type = "oci" },
        { tls = { ca_cert = var.registry_ca_pem == null ? "/etc/platform-ca/ca.crt" : "/etc/registry-ca/ca.crt" } },
        var.registry_credentials_secret == null ? {} : {
          credentials = { bearer = { scheme = "Basic", token_path = "/etc/registry-credentials/token" } }
        },
      )
    }
    bundles = {
      lakehouse = {
        service  = "registry"
        resource = var.bundle_ref
        persist  = true
        polling  = { min_delay_seconds = var.bundle_polling_seconds.min, max_delay_seconds = var.bundle_polling_seconds.max }
      }
    }
    persistence_directory = "/var/opa"
    decision_logs         = { console = var.decision_logs }
    status                = { console = false }
  })
  config_hash = substr(sha256(local.config), 0, 16)
}

module "tls" {
  count          = var.tls ? 1 : 0
  source         = "../tls-certificate"
  name           = "${var.name}-tls"
  namespace      = var.namespace
  dns_names      = [local.host, "${local.host}.cluster.local"]
  key_encoding   = "PKCS8"
  cluster_issuer = var.cluster_issuer
  labels         = var.labels
}

resource "kubernetes_config_map_v1" "config" {
  metadata {
    name      = "${var.name}-config"
    namespace = var.namespace
    labels    = local.labels
  }
  data = merge(
    { "config.yaml" = local.config },
    var.registry_ca_pem == null ? {} : { "registry-ca.crt" = var.registry_ca_pem },
  )
}

resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  automount_service_account_token = false
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    selector = local.selector_labels
    port {
      name        = local.scheme
      port        = 8181
      target_port = "api"
    }
    port {
      name        = "diagnostic"
      port        = 8282
      target_port = "diagnostic"
    }
  }
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    replicas = var.replicas
    selector {
      match_labels = local.selector_labels
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = var.replicas > 1 ? "1" : "0"
        max_surge       = "1"
      }
    }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "boccob.io/config-hash" = local.config_hash
        }
      }
      spec {
        service_account_name            = kubernetes_service_account_v1.this.metadata[0].name
        automount_service_account_token = false
        enable_service_links            = false
        # the registry name must be resolved as it is, not through the cluster search domains
        dns_config {
          option {
            name  = "ndots"
            value = "1"
          }
        }
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          fs_group        = 65532
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        dynamic "topology_spread_constraint" {
          for_each = var.replicas > 1 ? [1] : []
          content {
            max_skew           = 1
            topology_key       = "kubernetes.io/hostname"
            when_unsatisfiable = "ScheduleAnyway"
            label_selector {
              match_labels = local.selector_labels
            }
          }
        }
        container {
          name  = "opa"
          image = var.image
          args = concat(
            [
              "run", "--server",
              "--addr=0.0.0.0:8181",
              "--diagnostic-addr=0.0.0.0:8282",
              "--config-file=/config/config.yaml",
              "--log-level=${var.log_level}",
              "--log-format=json",
            ],
            var.tls ? [
              "--tls-cert-file=/tls/tls.crt",
              "--tls-private-key-file=/tls/tls.key",
              "--tls-cert-refresh-period=1h",
            ] : [],
          )
          port {
            name           = "api"
            container_port = 8181
          }
          port {
            name           = "diagnostic"
            container_port = 8282
          }
          # ready only once the bundle is activated: Trino must never get an
          # answer from an OPA without policies
          readiness_probe {
            http_get {
              path = "/health?bundles"
              port = "diagnostic"
            }
            period_seconds    = 5
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = "diagnostic"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "ca"
            mount_path = "/etc/platform-ca"
            read_only  = true
          }
          dynamic "volume_mount" {
            for_each = var.registry_ca_pem == null ? [] : [1]
            content {
              name       = "registry-ca"
              mount_path = "/etc/registry-ca"
              read_only  = true
            }
          }
          dynamic "volume_mount" {
            for_each = var.registry_credentials_secret == null ? [] : [1]
            content {
              name       = "registry-credentials"
              mount_path = "/etc/registry-credentials"
              read_only  = true
            }
          }
          dynamic "volume_mount" {
            for_each = var.tls ? [1] : []
            content {
              name       = "tls"
              mount_path = "/tls"
              read_only  = true
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/opa"
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.config.metadata[0].name
            items {
              key  = "config.yaml"
              path = "config.yaml"
            }
          }
        }
        volume {
          name = "ca"
          config_map {
            name = var.ca_configmap
          }
        }
        dynamic "volume" {
          for_each = var.registry_ca_pem == null ? [] : [1]
          content {
            name = "registry-ca"
            config_map {
              name = kubernetes_config_map_v1.config.metadata[0].name
              items {
                key  = "registry-ca.crt"
                path = "ca.crt"
              }
            }
          }
        }
        dynamic "volume" {
          for_each = var.registry_credentials_secret == null ? [] : [1]
          content {
            name = "registry-credentials"
            secret {
              secret_name = var.registry_credentials_secret
            }
          }
        }
        dynamic "volume" {
          for_each = var.tls ? [1] : []
          content {
            name = "tls"
            secret {
              secret_name = module.tls[0].secret_name
            }
          }
        }
        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
  timeouts {
    create = "5m"
    update = "5m"
  }
}

resource "kubernetes_pod_disruption_budget_v1" "this" {
  count = var.replicas > 1 ? 1 : 0
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.selector_labels
    }
  }
}

# --- network: only the policy clients may query, only the registry is reachable --
resource "kubernetes_network_policy_v1" "this" {
  metadata {
    name      = "${var.name}-access"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    pod_selector {
      match_labels = local.selector_labels
    }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector {
          match_labels = var.client_pod_labels
        }
      }
      ports {
        port     = "8181"
        protocol = "TCP"
      }
    }
    dynamic "ingress" {
      for_each = length(var.metrics_namespaces) > 0 ? [1] : []
      content {
        dynamic "from" {
          for_each = var.metrics_namespaces
          content {
            namespace_selector {
              match_labels = { "kubernetes.io/metadata.name" = from.value }
            }
          }
        }
        ports {
          port     = "8282"
          protocol = "TCP"
        }
      }
    }
    egress {
      dynamic "to" {
        for_each = var.registry_egress_cidrs
        content {
          ip_block {
            cidr = to.value
          }
        }
      }
      ports {
        port     = tostring(var.registry_port)
        protocol = "TCP"
      }
    }
  }
}
