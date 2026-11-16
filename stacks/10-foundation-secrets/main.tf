# 10-foundation-secrets: bootstrap CA + OpenBao (sealed, uninitialised).
# After apply, scripts/openbao/init.sh initialises and unseals (STACK_POST_APPLY).

# --- bootstrap CA ----------------------------------------------------------------
# A small cert-manager CA used ONLY for OpenBao's own listener certificate.
# Everything else is issued by the OpenBao PKI engine (ClusterIssuer openbao-pki).
resource "kubernetes_manifest" "selfsigned_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "bootstrap-selfsigned" }
    spec       = { selfSigned = {} }
  }
}

resource "kubernetes_manifest" "bootstrap_ca_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "bootstrap-ca"
      namespace = local.platform.namespaces.platform
    }
    spec = {
      isCA        = true
      commonName  = "Boccob Lakehouse ${var.environment} bootstrap CA"
      subject     = { organizations = ["Boccob Lakehouse"], organizationalUnits = [var.environment] }
      secretName  = "bootstrap-ca"
      duration    = "87600h0m0s"
      renewBefore = "8760h0m0s"
      privateKey  = { algorithm = "ECDSA", size = 384 }
      usages      = ["cert sign", "crl sign"]
      issuerRef   = { group = "cert-manager.io", kind = "ClusterIssuer", name = "bootstrap-selfsigned" }
    }
  }
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [kubernetes_manifest.selfsigned_issuer]
}

resource "kubernetes_manifest" "bootstrap_ca_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = local.platform.bootstrap_issuer }
    spec       = { ca = { secretName = "bootstrap-ca" } }
  }
  depends_on = [kubernetes_manifest.bootstrap_ca_cert]
}

# --- OpenBao ---------------------------------------------------------------------
module "ns_secrets" {
  source = "../../modules/namespace-baseline"
  name   = local.platform.namespaces.secrets
  labels = local.common_labels

  # kubernetes auth (TokenReview) + service registration (pod labels)
  allow_kube_api           = true
  ingress_controller_ports = [8200]

  ingress_rules = [
    {
      name            = "clients"
      from_namespaces = concat([local.platform.namespaces.platform], var.openbao_client_namespaces)
      ports           = [8200]
    },
  ]
  resource_quota = {
    "requests.memory" = "2Gi"
    "limits.memory"   = "4Gi"
    "pods"            = "10"
  }
}

module "openbao" {
  source             = "../../modules/openbao"
  namespace          = module.ns_secrets.name
  chart              = module.versions.charts["openbao"]
  image              = module.versions.images["openbao"]
  replicas           = coalesce(var.openbao_replicas, var.ha ? 3 : 1)
  tls_issuer         = local.platform.bootstrap_issuer
  data_storage_size  = var.openbao_data_storage_size
  audit_storage_size = var.openbao_audit_storage_size
  storage_class      = var.storage_class
  resources          = var.openbao_resources

  depends_on = [kubernetes_manifest.bootstrap_ca_issuer]
}
