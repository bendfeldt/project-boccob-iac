resource "helm_release" "this" {
  name       = "cloudnative-pg"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    crds         = { create = true }
    replicaCount = var.ha ? 2 : 1
    image = {
      repository = var.image.repository
      tag        = var.image.tag_digest
    }
    resources = var.resources
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
