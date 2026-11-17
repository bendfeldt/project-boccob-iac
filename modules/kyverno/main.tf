locals {
  image = { for k, v in var.images : k => {
    registry   = v.registry
    repository = v.repository_path
    tag        = v.tag_digest
  } }
  pdb = { enabled = var.ha, minAvailable = 1 }
}

resource "helm_release" "this" {
  name       = "kyverno"
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    crds = {
      install = true
      # the CRD migration hook needs the kyverno-cli image and only matters when upgrading from old CRD versions
      migration = { enabled = false }
    }
    # hooks that need extra images (readiness-checker): the webhook
    # configurations are removed by the admission controller itself on shutdown
    webhooksCleanup = { enabled = false }
    config = {
      webhooks = {
        namespaceSelector = {
          matchExpressions = [{
            key      = "kubernetes.io/metadata.name"
            operator = "NotIn"
            values   = var.excluded_namespaces
          }]
        }
      }
    }
    global = { caCertificates = { data = var.registry_ca_pem } }
    features = {
      policyExceptions = { enabled = true, namespace = var.namespace }
      backgroundScan   = { enabled = true, backgroundScanInterval = var.background_scan_interval }
      logging          = { format = "json" }
    }
    admissionController = {
      replicas            = var.ha ? 3 : 1
      podDisruptionBudget = local.pdb
      initContainer       = { image = local.image["pre"] }
      container = {
        image     = local.image["admission"]
        resources = var.resources["admission"]
      }
    }
    backgroundController = {
      enabled             = var.background_controller_enabled
      replicas            = var.ha ? 2 : 1
      podDisruptionBudget = local.pdb
      image               = local.image["background"]
      resources           = var.resources["background"]
    }
    cleanupController = { enabled = false }
    reportsController = {
      replicas            = var.ha ? 2 : 1
      podDisruptionBudget = local.pdb
      image               = local.image["reports"]
      resources           = var.resources["reports"]
    }
  })]
}
