# Baseline configuration of OpenBao: KV v2, Kubernetes auth, two-tier PKI and
# the policies/roles for cert-manager and External Secrets.
# CA private keys are generated INSIDE OpenBao (type "internal") and never
# reach the OpenTofu state.

# --- KV v2 -----------------------------------------------------------------------
resource "vault_mount" "kv" {
  path        = var.kv_mount
  type        = "kv"
  options     = { version = "2" }
  description = "Platform secrets (KV v2). Layout: ${var.kv_mount}/<namespace>/<name>"
}

# --- Kubernetes auth ---------------------------------------------------------------
resource "vault_auth_backend" "kubernetes" {
  type        = "kubernetes"
  path        = "kubernetes"
  description = "Workload identity: Kubernetes ServiceAccount tokens"
}

resource "vault_kubernetes_auth_backend_config" "this" {
  backend = vault_auth_backend.kubernetes.path
  # OpenBao runs in the cluster: it validates tokens with its own
  # ServiceAccount (system:auth-delegator) and the in-pod CA.
  kubernetes_host = "https://kubernetes.default.svc"
}

# --- PKI: root (offline-style, long lived) + intermediate (issuing) ------------------
resource "vault_mount" "pki_root" {
  path                      = "pki"
  type                      = "pki"
  description               = "Internal root CA"
  default_lease_ttl_seconds = var.pki_root_ttl_hours * 3600
  max_lease_ttl_seconds     = var.pki_root_ttl_hours * 3600
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend      = vault_mount.pki_root.path
  type         = "internal"
  common_name  = "Boccob Lakehouse ${var.environment} Root CA"
  organization = "Boccob Lakehouse"
  ou           = var.environment
  ttl          = "${var.pki_root_ttl_hours}h"
  key_type     = "ec"
  key_bits     = 384
  issuer_name  = "root"
}

resource "vault_pki_secret_backend_config_urls" "root" {
  backend                 = vault_mount.pki_root.path
  issuing_certificates    = ["${var.openbao_url}/v1/pki/ca"]
  crl_distribution_points = ["${var.openbao_url}/v1/pki/crl"]
}

resource "vault_mount" "pki_int" {
  path                      = "pki_int"
  type                      = "pki"
  description               = "Internal issuing CA (cert-manager ClusterIssuer)"
  default_lease_ttl_seconds = var.pki_max_leaf_ttl_hours * 3600
  max_lease_ttl_seconds     = var.pki_intermediate_ttl_hours * 3600
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  backend      = vault_mount.pki_int.path
  type         = "internal"
  common_name  = "Boccob Lakehouse ${var.environment} Issuing CA"
  organization = "Boccob Lakehouse"
  ou           = var.environment
  key_type     = "ec"
  key_bits     = 384
}

resource "vault_pki_secret_backend_root_sign_intermediate" "int" {
  backend              = vault_mount.pki_root.path
  csr                  = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name          = "Boccob Lakehouse ${var.environment} Issuing CA"
  organization         = "Boccob Lakehouse"
  ou                   = var.environment
  ttl                  = "${var.pki_intermediate_ttl_hours}h"
  exclude_cn_from_sans = true
  depends_on           = [vault_pki_secret_backend_root_cert.root]
}

resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.pki_int.path
  certificate = "${vault_pki_secret_backend_root_sign_intermediate.int.certificate}\n${vault_pki_secret_backend_root_cert.root.certificate}"
}

resource "vault_pki_secret_backend_config_urls" "int" {
  backend                 = vault_mount.pki_int.path
  issuing_certificates    = ["${var.openbao_url}/v1/pki_int/ca"]
  crl_distribution_points = ["${var.openbao_url}/v1/pki_int/crl"]
}

resource "vault_pki_secret_backend_role" "platform" {
  backend                     = vault_mount.pki_int.path
  name                        = "platform"
  allowed_domains             = var.pki_allowed_domains
  allow_subdomains            = true
  allow_bare_domains          = true
  allow_glob_domains          = false
  allow_wildcard_certificates = true
  allow_localhost             = true
  allow_ip_sans               = true
  server_flag                 = true
  client_flag                 = true
  key_type                    = "any"
  max_ttl                     = var.pki_max_leaf_ttl_hours * 3600
  ttl                         = var.pki_max_leaf_ttl_hours * 3600
  require_cn                  = false
  # cert-manager sends a CSR: honour its SANs, never copy the CN blindly
  use_csr_common_name = true
  use_csr_sans        = true
  depends_on          = [vault_pki_secret_backend_intermediate_set_signed.int]
}

# --- policies ----------------------------------------------------------------------
resource "vault_policy" "cert_manager" {
  name   = "cert-manager"
  policy = <<-HCL
    path "${vault_mount.pki_int.path}/sign/${vault_pki_secret_backend_role.platform.name}" {
      capabilities = ["create", "update"]
    }
  HCL
}

resource "vault_policy" "eso_read" {
  count  = var.legacy_eso_roles ? 1 : 0
  name   = "external-secrets-read"
  policy = <<-HCL
    path "${vault_mount.kv.path}/data/*" {
      capabilities = ["read"]
    }
    path "${vault_mount.kv.path}/metadata/*" {
      capabilities = ["read", "list"]
    }
  HCL
}

resource "vault_policy" "eso_push" {
  count  = var.legacy_eso_roles ? 1 : 0
  name   = "external-secrets-push"
  policy = <<-HCL
    path "${vault_mount.kv.path}/data/*" {
      capabilities = ["create", "update", "read"]
    }
    path "${vault_mount.kv.path}/metadata/*" {
      capabilities = ["create", "update", "read", "list", "delete"]
    }
  HCL
}

resource "vault_policy" "platform_admin" {
  name   = "platform-admin"
  policy = <<-HCL
    # Day-2 administration for members of the Keycloak group platform-admin.
    # Deliberately excludes sys/raw, sys/rotate and audit device removal.
    path "${vault_mount.kv.path}/*" {
      capabilities = ["create", "read", "update", "delete", "list", "patch"]
    }
    path "sys/policies/acl/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "auth/*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
    path "sys/auth*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "sys/mounts*" {
      capabilities = ["create", "read", "update", "list"]
    }
    path "${vault_mount.pki_int.path}/*" {
      capabilities = ["create", "read", "update", "list"]
    }
    path "${vault_mount.pki_root.path}/*" {
      capabilities = ["read", "list"]
    }
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
    path "sys/health" {
      capabilities = ["read", "sudo"]
    }
  HCL
}

resource "vault_policy" "auditor" {
  name   = "auditor"
  policy = <<-HCL
    # Read-only view of configuration for auditors; no secret data.
    path "sys/audit" {
      capabilities = ["read", "sudo"]
    }
    path "sys/policies/acl/*" {
      capabilities = ["read", "list"]
    }
    path "sys/auth" {
      capabilities = ["read"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "${vault_mount.kv.path}/metadata/*" {
      capabilities = ["list"]
    }
  HCL
}

# --- kubernetes auth roles ---------------------------------------------------------
resource "vault_kubernetes_auth_backend_role" "cert_manager" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "cert-manager"
  bound_service_account_names      = [var.cert_manager.service_account]
  bound_service_account_namespaces = [var.cert_manager.namespace]
  audience                         = var.cert_manager.audience
  token_policies                   = [vault_policy.cert_manager.name]
  token_ttl                        = 600
  token_max_ttl                    = 900
}

resource "vault_kubernetes_auth_backend_role" "eso_read" {
  count                            = var.legacy_eso_roles ? 1 : 0
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "external-secrets"
  bound_service_account_names      = [var.external_secrets.service_account]
  bound_service_account_namespaces = [var.external_secrets.namespace]
  token_policies                   = [vault_policy.eso_read[0].name]
  token_ttl                        = 600
  token_max_ttl                    = 900
}

resource "vault_kubernetes_auth_backend_role" "eso_push" {
  count                            = var.legacy_eso_roles ? 1 : 0
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "external-secrets-push"
  bound_service_account_names      = [var.external_secrets.service_account]
  bound_service_account_namespaces = [var.external_secrets.namespace]
  token_policies                   = [vault_policy.eso_push[0].name]
  token_ttl                        = 600
  token_max_ttl                    = 900
}

# --- per-namespace External Secrets access ------------------------------------------
resource "vault_policy" "ns_read" {
  for_each = var.namespace_stores
  name     = "eso-${each.key}-read"
  policy = join("\n", concat(
    [<<-HCL
      path "${vault_mount.kv.path}/data/${each.key}/*" {
        capabilities = ["read"]
      }
      path "${vault_mount.kv.path}/metadata/${each.key}/*" {
        capabilities = ["read", "list"]
      }
    HCL
    ],
    [for p in each.value.reads : <<-HCL
      path "${vault_mount.kv.path}/data/${p}" {
        capabilities = ["read"]
      }
      path "${vault_mount.kv.path}/metadata/${p}" {
        capabilities = ["read"]
      }
    HCL
    ],
  ))
}

resource "vault_policy" "ns_push" {
  for_each = var.namespace_stores
  name     = "eso-${each.key}-push"
  policy = join("\n", concat(
    [<<-HCL
      path "${vault_mount.kv.path}/data/${each.key}/*" {
        capabilities = ["create", "update", "read"]
      }
      path "${vault_mount.kv.path}/metadata/${each.key}/*" {
        capabilities = ["read", "list"]
      }
    HCL
    ],
    [for p in each.value.deny_write : <<-HCL
      path "${vault_mount.kv.path}/data/${p}" {
        capabilities = ["deny"]
      }
      path "${vault_mount.kv.path}/metadata/${p}" {
        capabilities = ["deny"]
      }
    HCL
    ],
  ))
}

resource "vault_kubernetes_auth_backend_role" "ns_read" {
  for_each                         = var.namespace_stores
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "eso-${each.key}-read"
  bound_service_account_names      = ["eso-read"]
  bound_service_account_namespaces = [each.key]
  token_policies                   = [vault_policy.ns_read[each.key].name]
  token_ttl                        = 600
  token_max_ttl                    = 900
}

resource "vault_kubernetes_auth_backend_role" "ns_push" {
  for_each                         = var.namespace_stores
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "eso-${each.key}-push"
  bound_service_account_names      = ["eso-push"]
  bound_service_account_namespaces = [each.key]
  token_policies                   = [vault_policy.ns_push[each.key].name]
  token_ttl                        = 600
  token_max_ttl                    = 900
}
