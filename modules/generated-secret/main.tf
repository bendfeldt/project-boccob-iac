# Generates random secret values IN THE CLUSTER (External Secrets "Password"
# generator) into <name>-seed, pushes them to OpenBao KV create-only
# (PushSecret IfNotExists) and materialises the Secret <name> from OpenBao.
# OpenBao is the source of truth: after a DR restore of OpenBao the restored
# values are used, not new ones. No value passes through OpenTofu.
#
# Rotation: delete the KV entry (bao kv metadata delete kv/<kv_path>) and the
# Secret <name>-seed; a new value is generated, pushed and synced (<= 1 h, or
# force: kubectl annotate externalsecret <name> force-sync=$(date +%s)).

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

# Seed: generated once, never overwritten, pushed to OpenBao create-only.
resource "kubernetes_manifest" "seed" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${var.name}-seed"
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      refreshPolicy = "CreatedOnce"
      target = {
        name           = "${var.name}-seed"
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

# The Secret workloads consume: always read back from OpenBao, so that a value
# restored into OpenBao (DR) wins over a freshly generated seed, and consumers
# in this and other namespaces see the same value.
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
      refreshPolicy   = "Periodic"
      refreshInterval = "1h0m0s"
      secretStoreRef  = { name = var.read_store, kind = var.store_kind }
      target = {
        name           = var.name
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          mergePolicy   = "Merge"
          metadata      = { labels = var.labels }
        }
      }
      dataFrom = [{ extract = { key = var.kv_path } }]
    }
  }
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  timeouts {
    create = "5m"
    update = "5m"
  }
  depends_on = [kubernetes_manifest.push]
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
      # create-only: never overwrite a value that exists in OpenBao (e.g. one
      # restored from a snapshot after a rebuild)
      updatePolicy   = "IfNotExists"
      deletionPolicy = "None"
      secretStoreRefs = [
        { name = var.push_store, kind = var.store_kind },
      ]
      selector = { secret = { name = "${var.name}-seed" } }
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
  depends_on = [kubernetes_manifest.seed]
}
