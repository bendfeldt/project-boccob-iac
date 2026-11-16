resource "kubernetes_manifest" "this" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      refreshInterval = var.refresh_interval
      secretStoreRef  = { name = var.store, kind = "ClusterSecretStore" }
      target = {
        name           = var.name
        creationPolicy = "Owner"
        deletionPolicy = "Retain"
        template = merge(
          { engineVersion = "v2", type = var.secret_type },
          length(var.template) > 0 ? { data = var.template } : {},
        )
      }
      dataFrom = [
        { extract = { key = var.kv_path } },
      ]
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
    update = "3m"
  }
}
