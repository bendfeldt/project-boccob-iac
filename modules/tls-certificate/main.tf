# Server certificate from the platform PKI: 90 days, renewed after 60, new key
# on every renewal.
resource "kubernetes_manifest" "this" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      secretName  = var.name
      commonName  = var.dns_names[0]
      duration    = "2160h0m0s"
      renewBefore = "720h0m0s"
      privateKey = {
        algorithm      = var.key_algorithm
        size           = var.key_algorithm == "RSA" ? 2048 : 256
        encoding       = var.key_encoding
        rotationPolicy = "Always"
      }
      usages    = var.usages
      dnsNames  = var.dns_names
      issuerRef = { group = "cert-manager.io", kind = "ClusterIssuer", name = var.cluster_issuer }
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
