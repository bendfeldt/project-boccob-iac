locals {
  transport_name = "${var.name}-backend"
}

# TLS to the backend: verify the pod certificate against the platform CA.
resource "kubernetes_manifest" "servers_transport" {
  count = var.backend_tls == null ? 0 : 1
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransport"
    metadata = {
      name      = local.transport_name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      serverName = var.backend_tls.server_name
      rootCAs = [
        { configMap = var.backend_tls.ca_configmap },
      ]
    }
  }
}

resource "kubernetes_annotations" "service" {
  count       = var.backend_tls == null ? 0 : 1
  api_version = "v1"
  kind        = "Service"
  metadata {
    name      = var.service_name
    namespace = var.namespace
  }
  annotations = {
    "traefik.ingress.kubernetes.io/service.serversscheme"    = "https"
    "traefik.ingress.kubernetes.io/service.serverstransport" = "${var.namespace}-${local.transport_name}@kubernetescrd"
  }
  field_manager = "boccob-ingress-${var.name}"
  depends_on    = [kubernetes_manifest.servers_transport]
}

resource "kubernetes_ingress_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = var.labels
    annotations = merge({
      "cert-manager.io/cluster-issuer"                   = var.cluster_issuer
      "cert-manager.io/private-key-algorithm"            = "ECDSA"
      "cert-manager.io/private-key-rotation-policy"      = "Always"
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }, var.annotations)
  }
  spec {
    ingress_class_name = var.ingress_class
    tls {
      hosts       = [var.host]
      secret_name = "${var.name}-ingress-tls"
    }
    rule {
      host = var.host
      http {
        path {
          path      = var.path
          path_type = "Prefix"
          backend {
            service {
              name = var.service_name
              port {
                number = var.service_port
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_annotations.service]
}
