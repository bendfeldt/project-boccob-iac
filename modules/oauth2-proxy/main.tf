# oauth2-proxy in front of an application without its own authentication:
# OIDC login against Keycloak, access restricted to Keycloak groups, HTTPS
# towards the ingress controller with a certificate from the platform PKI.

locals {
  host            = "${var.name}.${var.namespace}.svc"
  selector_labels = { "app.kubernetes.io/name" = var.name }
  labels          = merge(var.labels, local.selector_labels, { "app.kubernetes.io/component" = "oauth2-proxy" })
}

module "cookie_secret" {
  source    = "../generated-secret"
  name      = "${var.name}-cookie"
  namespace = var.namespace
  kv_path   = "${var.kv_prefix}/cookie-secret"
  keys      = ["cookie-secret"]
  length    = 32 # AES-256 key
  labels    = var.labels
}

module "client_secret" {
  source    = "../external-secret"
  name      = "${var.name}-oidc"
  namespace = var.namespace
  kv_path   = var.oidc.client_secret_kv_path
  labels    = var.labels
}

module "tls" {
  source         = "../tls-certificate"
  name           = "${var.name}-tls"
  namespace      = var.namespace
  dns_names      = [local.host, "${local.host}.cluster.local"]
  cluster_issuer = var.cluster_issuer
  labels         = var.labels
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    selector = local.selector_labels
    port {
      name        = "https"
      port        = 8443
      target_port = "https"
    }
  }
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    replicas = var.replicas
    selector {
      match_labels = local.selector_labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        automount_service_account_token = false
        enable_service_links            = false
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "oauth2-proxy"
          image = var.image
          args = [
            "--provider=keycloak-oidc",
            "--oidc-issuer-url=${var.oidc.issuer}",
            "--client-id=${var.oidc.client_id}",
            "--client-secret-file=/secrets/oidc/client-secret",
            "--cookie-secret-file=/secrets/cookie/cookie-secret",
            "--cookie-name=_${replace(var.name, "-", "_")}",
            "--cookie-secure=true",
            "--cookie-samesite=lax",
            "--code-challenge-method=S256",
            "--redirect-url=https://${var.public_host}/oauth2/callback",
            "--upstream=${var.upstream}",
            "--email-domain=*",
            "--scope=openid profile email",
            "--provider-ca-file=/etc/platform-ca/ca.crt",
            "--reverse-proxy=true",
            "--skip-provider-button=true",
            "--pass-access-token=false",
            "--set-xauthrequest=true",
            "--http-address=127.0.0.1:4180",
            "--https-address=0.0.0.0:8443",
            "--tls-cert-file=/tls/tls.crt",
            "--tls-key-file=/tls/tls.key",
            "--tls-min-version=TLS1.2",
            "--allowed-group=${join(",", var.allowed_groups)}",
          ]
          port {
            name           = "https"
            container_port = 8443
          }
          readiness_probe {
            http_get {
              path   = "/ping"
              port   = "https"
              scheme = "HTTPS"
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path   = "/ping"
              port   = "https"
              scheme = "HTTPS"
            }
            initial_delay_seconds = 5
            period_seconds        = 20
          }
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }
          volume_mount {
            name       = "oidc"
            mount_path = "/secrets/oidc"
            read_only  = true
          }
          volume_mount {
            name       = "cookie"
            mount_path = "/secrets/cookie"
            read_only  = true
          }
          volume_mount {
            name       = "tls"
            mount_path = "/tls"
            read_only  = true
          }
          volume_mount {
            name       = "ca"
            mount_path = "/etc/platform-ca"
            read_only  = true
          }
        }
        volume {
          name = "oidc"
          secret {
            secret_name = module.client_secret.secret_name
          }
        }
        volume {
          name = "cookie"
          secret {
            secret_name = module.cookie_secret.secret_name
          }
        }
        volume {
          name = "tls"
          secret {
            secret_name = module.tls.secret_name
          }
        }
        volume {
          name = "ca"
          config_map {
            name = var.ca_configmap
          }
        }
      }
    }
  }
}
