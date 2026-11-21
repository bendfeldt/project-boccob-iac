# 00-bootstrap: cluster add-ons that everything else needs and that ship CRDs.
# CRDs must exist before another stack can plan custom resources, which is why
# operators live here and their custom resources live in later stacks.

module "ns_platform" {
  source = "../../modules/namespace-baseline"
  name   = local.platform.namespaces.platform
  labels = local.common_labels

  allow_kube_api = true
  secrets_access = false

  ingress_rules = [
    {
      # kube-apiserver -> admission/conversion webhooks (cert-manager, ESO: 10250, CNPG: 9443)
      name       = "webhooks"
      from_cidrs = var.cluster_cidrs
      ports      = [10250, 9443]
    },
    {
      # Prometheus: cert-manager 9402, External Secrets + CloudNativePG operator 8080
      name            = "metrics"
      from_namespaces = var.metrics_namespaces
      ports           = var.metrics_ports
    },
  ]
  egress_rules = [
    {
      # cert-manager (PKI issuer) and External Secrets -> OpenBao
      name          = "openbao"
      to_namespaces = [local.platform.namespaces.secrets]
      ports         = [8200]
    },
    {
      # CloudNativePG operator -> instance manager status API / postgres
      name          = "postgres-instances"
      to_namespaces = [local.platform.namespaces.database]
      ports         = [8000, 5432]
    },
  ]
}

module "cert_manager" {
  source    = "../../modules/cert-manager"
  namespace = module.ns_platform.name
  chart     = module.versions.charts["cert-manager"]
  images = {
    controller = module.versions.images["cert-manager-controller"]
    webhook    = module.versions.images["cert-manager-webhook"]
    cainjector = module.versions.images["cert-manager-cainjector"]
    acmesolver = module.versions.images["cert-manager-acmesolver"]
  }
  ha = var.ha
}

module "external_secrets" {
  source    = "../../modules/external-secrets"
  namespace = module.ns_platform.name
  chart     = module.versions.charts["external-secrets"]
  image     = module.versions.images["external-secrets"]
  ha        = var.ha
}

module "cloudnative_pg" {
  source    = "../../modules/cloudnative-pg"
  namespace = module.ns_platform.name
  chart     = module.versions.charts["cloudnative-pg"]
  image     = module.versions.images["cloudnative-pg"]
  ha        = var.ha
}

# --- ingress: harden the Traefik bundled with k3s -------------------------------
# k3s owns the Traefik HelmChart; HelmChartConfig is the supported way to
# customise it. Justification for keeping Traefik: it is part of the k3s
# air-gap image set (no extra mirroring), is maintained with k3s upgrades and
# supports per-backend TLS verification (ServersTransport).
locals {
  traefik_replicas = coalesce(var.traefik_replicas, var.ha ? 2 : 1)
  traefik_values = {
    deployment = { replicas = local.traefik_replicas }
    podDisruptionBudget = {
      enabled      = local.traefik_replicas > 1
      minAvailable = 1
    }
    # no anonymous usage statistics / version check (air-gap, privacy)
    globalArguments = []
    # exposedPort = the Service (and ServiceLB host) port; the http->https redirect
    # targets it. Only set for a non-default public port (macOS without the pf
    # redirect): <svc>.<base_domain>:<port> then works in the cluster and outside.
    ports = {
      web = merge({
        http = {
          redirections = {
            entryPoint = { to = "websecure", scheme = "https", permanent = true }
          }
        }
      }, var.public_https_port == 443 ? {} : { exposedPort = var.public_http_port })
      websecure = merge({
        http = { tls = { enabled = true } }
      }, var.public_https_port == 443 ? {} : { exposedPort = var.public_https_port })
    }
    ingressRoute = { dashboard = { enabled = false } }
    api          = { dashboard = false, insecure = false }
    providers = {
      kubernetesCRD = {
        allowCrossNamespace       = false
        allowExternalNameServices = false
      }
      kubernetesIngress = {
        allowExternalNameServices = false
        publishedService          = { enabled = true }
      }
    }
    tlsOptions = {
      default = {
        minVersion = "VersionTLS12"
        sniStrict  = true
        cipherSuites = [
          "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
          "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
          "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
          "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
          "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305",
          "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305",
        ]
      }
    }
    logs = {
      general = { format = "json", level = "INFO" }
      access  = { enabled = true, format = "json" }
    }
    resources = {
      requests = { cpu = "20m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  }
}

resource "kubernetes_manifest" "traefik_config" {
  manifest = {
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "traefik"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = yamlencode(local.traefik_values)
    }
  }
}

# --- in-cluster resolution of ingress hostnames ---------------------------------
# OIDC needs the SAME issuer URL inside and outside the cluster. Pods resolve
# <svc>.<base_domain> to the Traefik Service so they use the ingress like any
# external client (TLS from the internal CA included).
resource "kubernetes_config_map_v1" "coredns_custom" {
  count = var.ingress_dns_rewrite ? 1 : 0
  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
    labels    = local.common_labels
  }
  data = {
    "lakehouse.override" = join("\n", concat(
      [for name in var.ingress_dns_rewrite_exclude : "rewrite stop name exact ${name} ${name}"],
      ["rewrite stop name regex ^(.*)\\.${replace(var.base_domain, ".", "\\.")}\\.$ traefik.kube-system.svc.cluster.local answer auto"],
    ))
  }
}
