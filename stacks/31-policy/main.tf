# 31-policy: admission control and supply-chain policy.
#   - Kyverno (namespace kyverno)
#   - OpenBao transit key that signs the solution artefacts (cosign); the
#     private key never leaves OpenBao, the public key is read here and handed
#     to the image verification policy
#   - the policy set (modules/kyverno-policies)

provider "vault" {
  skip_child_token = true
}

locals {
  registry_ca_pem = file(coalesce(var.registry_ca_file, pathexpand("~/.boccob/${var.environment}/pki/registry-ca.crt")))
  registry_port   = length(split(":", var.registry_host)) > 1 ? tonumber(split(":", var.registry_host)[1]) : 443
  kyverno_ns      = "kyverno"
}

module "ns_kyverno" {
  source = "../../modules/namespace-baseline"
  name   = local.kyverno_ns
  labels = local.common_labels

  allow_kube_api = true
  ingress_rules = [
    {
      # kube-apiserver -> admission webhooks
      name       = "webhooks"
      from_cidrs = var.cluster_cidrs
      ports      = [9443]
    },
    {
      name            = "metrics"
      from_namespaces = var.metrics_namespaces
      ports           = [8000]
    },
  ]
  egress_rules = [
    {
      # image manifests and cosign signatures are read from the Zot mirror
      name     = "registry"
      to_cidrs = coalesce(var.registry_cidrs, var.cluster_cidrs)
      ports    = [local.registry_port]
    },
  ]
  # the controllers set their own resources
  limit_range = {}
}

module "kyverno" {
  source    = "../../modules/kyverno"
  namespace = module.ns_kyverno.name
  chart     = module.versions.charts["kyverno"]
  images = {
    admission  = module.versions.images["kyverno"]
    pre        = module.versions.images["kyverno-pre"]
    background = module.versions.images["kyverno-background-controller"]
    reports    = module.versions.images["kyverno-reports-controller"]
  }
  ha                            = var.ha
  registry_ca_pem               = local.registry_ca_pem
  background_controller_enabled = var.kyverno_background_controller_enabled
  resources                     = var.kyverno_resources
}
