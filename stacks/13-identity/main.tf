# 13-identity: Keycloak (namespace identity, realm lakehouse, OIDC clients) and
# its PostgreSQL cluster keycloak-db (namespace database, owned by stack 12).
# Split out of 12-foundation-services (state Secret size, docs/architecture.md);
# the resources were moved with their state, nothing was recreated.

data "kubernetes_config_map_v1" "platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = local.platform.namespaces.platform
  }
}

locals {
  ns              = local.platform.namespaces
  platform_ca_pem = data.kubernetes_config_map_v1.platform_ca.data["ca.crt"]
  default_oidc_clients = {
    trino = {
      name          = "Trino"
      redirect_uris = ["https://trino.${var.base_domain}${local.platform.public_port}/oauth2/callback", "https://trino.${var.base_domain}${local.platform.public_port}/ui/logout/logout.html"]
    }
    polaris = {
      name            = "Apache Polaris"
      redirect_uris   = ["https://polaris.${var.base_domain}${local.platform.public_port}/*"]
      service_account = true
    }
    dagster = {
      name          = "Dagster (oauth2-proxy)"
      redirect_uris = ["https://dagster.${var.base_domain}${local.platform.public_port}/oauth2/callback"]
    }
    grafana = {
      name          = "Grafana"
      redirect_uris = ["https://grafana.${var.base_domain}${local.platform.public_port}/login/generic_oauth"]
    }
    # audit trail viewer (stack 30-observability); login restricted to the auditor group
    grafana-audit = {
      name          = "Grafana (audit trail)"
      redirect_uris = ["https://grafana-audit.${var.base_domain}${local.platform.public_port}/login/generic_oauth"]
    }
    openbao = {
      name = "OpenBao"
      redirect_uris = [
        "https://openbao.${var.base_domain}${local.platform.public_port}/ui/vault/auth/oidc/oidc/callback",
        "http://localhost:8250/oidc/callback",
      ]
    }
  }
  oidc_clients = merge(local.default_oidc_clients, var.oidc_clients)
}

# =============================================================================
# PostgreSQL cluster keycloak-db (namespace database)
# =============================================================================
locals {
  postgres_backup = var.postgres_backup == null ? null : {
    ca_secret          = local.platform.ca_configmap # Secret in namespace database (stack 12)
    destination_path   = "s3://platform-backup/postgres"
    endpoint_url       = local.platform.s3_url
    credentials_secret = "platform-backup-s3" # namespace database (stack 12)
    retention_policy   = var.postgres_backup.retention_policy
    schedule           = var.postgres_backup.schedule
    encryption         = var.rustfs_sse_enabled ? "AES256" : null
  }
}

module "keycloak_db" {
  source        = "../../modules/postgres-cluster"
  push_store    = "openbao-push"
  store_kind    = "SecretStore" # namespace database (stack 12)
  name          = "keycloak-db"
  namespace     = local.ns.database
  image         = module.versions.images["postgresql"].ref
  instances     = coalesce(var.postgres_instances, var.ha ? 3 : 1)
  database      = "keycloak"
  backup        = local.postgres_backup
  storage_size  = var.postgres_storage_size
  storage_class = var.storage_class
  resources     = var.postgres_resources
  labels        = local.common_labels
}

# =============================================================================
# Keycloak
# =============================================================================
module "ns_identity" {
  source = "../../modules/namespace-baseline"
  name   = local.ns.identity
  labels = local.common_labels

  secrets_access           = true
  ca_bundle_pem            = local.platform_ca_pem
  ingress_controller_ports = [8443]

  ingress_rules = concat(
    length(var.keycloak_client_namespaces) == 0 ? [] : [{
      name            = "clients"
      from_namespaces = var.keycloak_client_namespaces
      ports           = [8443]
    }],
    [{
      name            = "metrics"
      from_namespaces = var.metrics_namespaces
      ports           = [9000]
    }],
  )
  egress_rules = [
    {
      name          = "postgres"
      to_namespaces = [local.ns.database]
      ports         = [5432]
    },
  ]
  resource_quota = {
    "requests.memory" = "3Gi"
    "limits.memory"   = "6Gi"
    "pods"            = "15"
  }
}

module "keycloak_db_credentials" {
  source     = "../../modules/external-secret"
  store      = module.ns_identity.secret_stores.read
  store_kind = module.ns_identity.secret_stores.kind
  name       = "keycloak-db"
  namespace  = module.ns_identity.name
  kv_path    = module.keycloak_db.kv_path
  labels     = local.common_labels
}

module "keycloak" {
  source        = "../../modules/keycloak"
  secret_stores = module.ns_identity.secret_stores
  namespace     = module.ns_identity.name
  image         = module.versions.images["keycloak"].ref
  replicas      = coalesce(var.keycloak_replicas, var.ha ? 2 : 1)
  hostname      = "keycloak.${var.base_domain}"
  public_port   = local.platform.public_port
  database = {
    host   = module.keycloak_db.host
    name   = module.keycloak_db.database
    secret = module.keycloak_db_credentials.secret_name
  }
  oidc_clients = local.oidc_clients
  resources    = var.keycloak_resources
  labels       = local.common_labels
}

module "ingress_keycloak" {
  source       = "../../modules/ingress-host"
  name         = "keycloak"
  namespace    = module.ns_identity.name
  host         = "keycloak.${var.base_domain}"
  service_name = module.keycloak.service
  service_port = 8443
  backend_tls  = { server_name = module.keycloak.internal_host }
  labels       = local.common_labels
}

