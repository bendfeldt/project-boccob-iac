# Generates random secret values IN THE CLUSTER (External Secrets "Password"
# generator), materialises them as a Kubernetes Secret and pushes them to
# OpenBao KV. No value ever passes through OpenTofu (state, plan or logs).
#
# Rotation: delete the Kubernetes Secret; a new value is generated and pushed.

resource "kubernetes_manifest" "generator" {
  manifest = {
    apiVersion = "generators.external-secrets.io/v1alpha1"
    kind       = "Password"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      length      = var.length
      digits      = 8
      symbols     = 0
      noUpper     = false
      allowRepeat = true
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      # generate once, never overwrite an existing value
      refreshPolicy = "CreatedOnce"
      target = {
        name           = var.name
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          mergePolicy   = "Merge"
          metadata      = { labels = var.labels }
          data          = var.literals
        }
      }
      dataFrom = [
        for key in var.keys : {
          sourceRef = {
            generatorRef = {
              apiVersion = "generators.external-secrets.io/v1alpha1"
              kind       = "Password"
              name       = var.name
            }
          }
          rewrite = [
            { regexp = { source = "^password$", target = key } },
          ]
        }
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
  depends_on = [kubernetes_manifest.generator]
}

resource "kubernetes_manifest" "push" {
  manifest = {
    apiVersion = "external-secrets.io/v1alpha1"
    kind       = "PushSecret"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      refreshInterval = "1h0m0s"
      updatePolicy    = "Replace"
      deletionPolicy  = "None"
      secretStoreRefs = [
        { name = var.push_store, kind = "ClusterSecretStore" },
      ]
      selector = { secret = { name = var.name } }
      data = [
        for key in concat(var.keys, keys(var.literals)) : {
          match = {
            secretKey = key
            remoteRef = { remoteKey = var.kv_path, property = key }
          }
        }
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
  depends_on = [kubernetes_manifest.external_secret]
}
