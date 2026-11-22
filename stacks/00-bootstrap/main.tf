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

# --- operators (one chart each; images from the Zot mirror, pinned by digest) ----
locals {
  operator_replicas = var.ha ? 2 : 1
  operator_pdb      = { enabled = var.ha, minAvailable = 1 }
  cert_manager_image = { for k, key in {
    controller = "cert-manager-controller"
    webhook    = "cert-manager-webhook"
    cainjector = "cert-manager-cainjector"
    acmesolver = "cert-manager-acmesolver"
    } : k => {
    repository = module.versions.images[key].repository
    tag        = module.versions.images[key].tag
    digest     = module.versions.images[key].digest
  } }
  eso_image = {
    repository = module.versions.images["external-secrets"].repository
    tag        = module.versions.images["external-secrets"].tag_digest
  }
  eso_resources = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = module.ns_platform.name
  repository = module.versions.charts["cert-manager"].repository
  chart      = module.versions.charts["cert-manager"].name
  version    = module.versions.charts["cert-manager"].version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    crds = { enabled = true, keep = true }
    global = {
      leaderElection = { namespace = module.ns_platform.name }
    }
    image               = local.cert_manager_image["controller"]
    replicaCount        = local.operator_replicas
    podDisruptionBudget = local.operator_pdb
    resources           = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    # Certificates own their Secrets: deleting a Certificate removes the key material
    enableCertificateOwnerRef = true
    config = {
      apiVersion = "controller.config.cert-manager.io/v1alpha1"
      kind       = "ControllerConfiguration"
      logging    = { format = "json" }
    }
    prometheus = { enabled = true, servicemonitor = { enabled = false } }
    webhook = {
      image               = local.cert_manager_image["webhook"]
      replicaCount        = local.operator_replicas
      podDisruptionBudget = local.operator_pdb
      resources           = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "128Mi" } }
    }
    cainjector = {
      image               = local.cert_manager_image["cainjector"]
      replicaCount        = local.operator_replicas
      podDisruptionBudget = local.operator_pdb
      resources           = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    }
    acmesolver      = { image = local.cert_manager_image["acmesolver"] }
    startupapicheck = { enabled = false }
  })]
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  namespace  = module.ns_platform.name
  repository = module.versions.charts["external-secrets"].repository
  chart      = module.versions.charts["external-secrets"].name
  version    = module.versions.charts["external-secrets"].version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    installCRDs         = true
    image               = local.eso_image
    replicaCount        = local.operator_replicas
    leaderElect         = var.ha
    podDisruptionBudget = local.operator_pdb
    resources           = local.eso_resources
    log                 = { level = "info", timeEncoding = "iso8601" }
    webhook = {
      image               = local.eso_image
      replicaCount        = local.operator_replicas
      podDisruptionBudget = local.operator_pdb
      resources           = local.eso_resources
    }
    certController = {
      image               = local.eso_image
      replicaCount        = local.operator_replicas
      podDisruptionBudget = local.operator_pdb
      resources           = local.eso_resources
    }
  })]
}

resource "helm_release" "cloudnative_pg" {
  name       = "cloudnative-pg"
  namespace  = module.ns_platform.name
  repository = module.versions.charts["cloudnative-pg"].repository
  chart      = module.versions.charts["cloudnative-pg"].name
  version    = module.versions.charts["cloudnative-pg"].version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    crds         = { create = true }
    replicaCount = local.operator_replicas
    image = {
      repository = module.versions.images["cloudnative-pg"].repository
      tag        = module.versions.images["cloudnative-pg"].tag_digest
    }
    resources = { requests = { cpu = "20m", memory = "100Mi" }, limits = { memory = "256Mi" } }
    config = {
      clusterWide = true
      data = {
        # labels/annotations copied from Cluster objects to pods and secrets
        INHERITED_LABELS      = "app.kubernetes.io/*,boccob.io/*"
        INHERITED_ANNOTATIONS = "boccob.io/*"
      }
    }
    monitoring = { podMonitorEnabled = false }
  })]
}

moved {
  from = module.cert_manager.helm_release.this
  to   = helm_release.cert_manager
}
moved {
  from = module.external_secrets.helm_release.this
  to   = helm_release.external_secrets
}
moved {
  from = module.cloudnative_pg.helm_release.this
  to   = helm_release.cloudnative_pg
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
    ports = {
      web = {
        http = {
          redirections = {
            entryPoint = { to = "websecure", scheme = "https", permanent = true }
          }
        }
      }
      websecure = {
        http = { tls = { enabled = true } }
      }
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
