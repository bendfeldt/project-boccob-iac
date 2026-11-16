locals {
  replicas = var.ha ? 2 : 1
  image = { for k, v in var.images : k => {
    repository = v.repository
    tag        = v.tag
    digest     = v.digest
  } }
  pdb = { enabled = var.ha, minAvailable = 1 }
}

resource "helm_release" "this" {
  name       = "cert-manager"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    crds = { enabled = true, keep = true }
    global = {
      leaderElection = { namespace = var.namespace }
    }
    image               = local.image["controller"]
    replicaCount        = local.replicas
    podDisruptionBudget = local.pdb
    resources           = var.resources.controller
    # Certificates own their Secrets: deleting a Certificate removes the key material
    enableCertificateOwnerRef = true
    config = {
      apiVersion = "controller.config.cert-manager.io/v1alpha1"
      kind       = "ControllerConfiguration"
      logging    = { format = "json" }
    }
    prometheus = { enabled = true, servicemonitor = { enabled = false } }
    webhook = {
      image               = local.image["webhook"]
      replicaCount        = local.replicas
      podDisruptionBudget = local.pdb
      resources           = var.resources.webhook
    }
    cainjector = {
      image               = local.image["cainjector"]
      replicaCount        = local.replicas
      podDisruptionBudget = local.pdb
      resources           = var.resources.cainjector
    }
    acmesolver      = { image = local.image["acmesolver"] }
    startupapicheck = { enabled = false }
  })]
}
