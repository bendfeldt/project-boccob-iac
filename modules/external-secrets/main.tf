locals {
  image    = { repository = var.image.repository, tag = var.image.tag_digest }
  replicas = var.ha ? 2 : 1
  pdb      = { enabled = var.ha, minAvailable = 1 }
}

resource "helm_release" "this" {
  name       = "external-secrets"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    installCRDs         = true
    image               = local.image
    replicaCount        = local.replicas
    leaderElect         = var.ha
    podDisruptionBudget = local.pdb
    resources           = var.resources
    log                 = { level = "info", timeEncoding = "iso8601" }
    webhook = {
      image               = local.image
      replicaCount        = local.replicas
      podDisruptionBudget = local.pdb
      resources           = var.resources
    }
    certController = {
      image               = local.image
      replicaCount        = local.replicas
      podDisruptionBudget = local.pdb
      resources           = var.resources
    }
  })]
}
