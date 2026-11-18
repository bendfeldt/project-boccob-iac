# 11-foundation-pki: configure OpenBao (KV, kubernetes auth, PKI) and wire
# cert-manager and External Secrets to it.

# Address, CA and token come from VAULT_ADDR / VAULT_CACERT / VAULT_TOKEN
# (scripts/tofu.sh). Nothing about the token is stored in code or tfvars.
provider "vault" {
  skip_child_token = true
}

locals {
  cert_manager_issuer_sa = "cert-manager-issuer"
  # trust anchors every workload needs: PKI root (+ issuing CA) and the bootstrap CA
  platform_ca_pem = join("\n", [
    trimspace(module.openbao_config.root_ca_pem),
    trimspace(module.openbao_config.issuing_ca_pem),
    trimspace(var.bootstrap_ca_pem),
    "",
  ])
}

module "openbao_config" {
  source      = "../../modules/openbao-config"
  environment = var.environment
  openbao_url = local.platform.openbao_url
  kv_mount    = local.platform.kv_mount

  pki_allowed_domains = concat(
    [var.base_domain, "svc", "svc.cluster.local", "cluster.local", "localhost"],
    var.pki_extra_allowed_domains,
  )
  pki_max_leaf_ttl_hours = var.pki_max_leaf_ttl_hours

  cert_manager = {
    service_account = local.cert_manager_issuer_sa
    namespace       = local.platform.namespaces.platform
    audience        = "vault://${local.platform.cluster_issuer}"
  }
  external_secrets = {
    service_account = "external-secrets"
    namespace       = local.platform.namespaces.platform
  }
  legacy_eso_roles = length(var.legacy_cluster_store_namespaces) > 0
  namespace_stores = {
    for ns, cfg in var.namespace_secret_stores : ns => {
      reads      = concat(cfg.reads, lookup(var.extra_namespace_secret_reads, ns, []))
      deny_write = cfg.deny_write
    }
  }
}

# --- trust bundle ------------------------------------------------------------------
resource "kubernetes_config_map_v1" "platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = local.platform.namespaces.platform
    labels    = local.common_labels
  }
  data = {
    "ca.crt" = local.platform_ca_pem
  }
}

# --- cert-manager -> OpenBao PKI ---------------------------------------------------
# cert-manager authenticates with a short-lived token of a dedicated
# ServiceAccount (no static OpenBao token anywhere).
resource "kubernetes_service_account_v1" "cert_manager_issuer" {
  metadata {
    name      = local.cert_manager_issuer_sa
    namespace = local.platform.namespaces.platform
    labels    = local.common_labels
  }
  automount_service_account_token = false
}

resource "kubernetes_role_v1" "cert_manager_issuer_token" {
  metadata {
    name      = "cert-manager-issuer-token"
    namespace = local.platform.namespaces.platform
    labels    = local.common_labels
  }
  rule {
    api_groups     = [""]
    resources      = ["serviceaccounts/token"]
    resource_names = [kubernetes_service_account_v1.cert_manager_issuer.metadata[0].name]
    verbs          = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "cert_manager_issuer_token" {
  metadata {
    name      = "cert-manager-issuer-token"
    namespace = local.platform.namespaces.platform
    labels    = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.cert_manager_issuer_token.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "cert-manager"
    namespace = local.platform.namespaces.platform
  }
}

resource "kubernetes_manifest" "cluster_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = local.platform.cluster_issuer }
    spec = {
      vault = {
        server   = local.platform.openbao_url
        path     = module.openbao_config.pki_sign_path
        caBundle = base64encode(var.bootstrap_ca_pem)
        auth = {
          kubernetes = {
            mountPath = "/v1/auth/${module.openbao_config.kubernetes_auth_path}"
            role      = module.openbao_config.roles.cert_manager
            serviceAccountRef = {
              name = kubernetes_service_account_v1.cert_manager_issuer.metadata[0].name
            }
          }
        }
      }
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
  }
  depends_on = [kubernetes_role_binding_v1.cert_manager_issuer_token]
}

# --- External Secrets -> OpenBao KV ------------------------------------------------
locals {
  secret_stores = {
    (local.platform.secret_store)      = module.openbao_config.roles.eso_read
    (local.platform.secret_store_push) = module.openbao_config.roles.eso_push
  }
}

# Legacy cluster-wide stores (full kv/* access): only while some namespace
# still needs them; with no legacy namespace they are removed.
resource "kubernetes_manifest" "cluster_secret_store" {
  for_each = length(var.legacy_cluster_store_namespaces) > 0 ? local.secret_stores : {}
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata   = { name = each.key }
    spec = {
      # only namespaces not yet migrated to their own SecretStores
      conditions = [{ namespaces = var.legacy_cluster_store_namespaces }]
      provider = {
        vault = {
          server  = local.platform.openbao_url
          path    = module.openbao_config.kv_mount
          version = "v2"
          caProvider = {
            type      = "ConfigMap"
            name      = kubernetes_config_map_v1.platform_ca.metadata[0].name
            namespace = local.platform.namespaces.platform
            key       = "ca.crt"
          }
          auth = {
            kubernetes = {
              mountPath = module.openbao_config.kubernetes_auth_path
              role      = each.value
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = local.platform.namespaces.platform
              }
            }
          }
        }
      }
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
  }
}
