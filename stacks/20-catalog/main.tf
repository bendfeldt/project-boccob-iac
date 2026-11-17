# 20-catalog: Apache Polaris (Iceberg REST catalog) with its own PostgreSQL
# metastore, one catalog per data layer and least-privilege service principals.

provider "vault" {
  skip_child_token = true
}

data "kubernetes_config_map_v1" "platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = local.platform.namespaces.platform
  }
}

locals {
  ns              = local.platform.namespaces
  platform_ca_pem = data.kubernetes_config_map_v1.platform_ca.data["ca.crt"]

  catalogs = {
    for layer in var.layers : layer => {
      base_location     = "s3://lakehouse-${layer}/iceberg"
      allowed_locations = ["s3://lakehouse-${layer}/"]
      # Trino DROP TABLE (dbt temporary tables, erasure) needs purge
      properties = { "polaris.config.drop-with-purge.enabled" = "true" }
    }
  }
}

module "ns_catalog" {
  source = "../../modules/namespace-baseline"
  name   = local.ns.catalog
  labels = local.common_labels

  secrets_access           = true
  ca_bundle_pem            = local.platform_ca_pem
  allow_ingress_hosts      = var.polaris_oidc_enabled # OIDC discovery through the public issuer URL
  ingress_controller_ports = [8181]

  ingress_rules = [
    {
      name            = "catalog-clients"
      from_namespaces = var.catalog_client_namespaces
      ports           = [8181]
    },
    {
      name            = "metrics"
      from_namespaces = var.metrics_namespaces
      ports           = [8182]
    },
  ]
  egress_rules = [
    { name = "postgres", to_namespaces = [local.ns.database], ports = [5432] },
    { name = "s3", to_namespaces = [local.ns.storage], ports = [9000] },
    # provisioning Job stores principal credentials in OpenBao
    { name = "openbao", to_namespaces = [local.ns.secrets], ports = [8200] },
  ]
  resource_quota = var.catalog_resource_quota
}

module "polaris_db" {
  source        = "../../modules/postgres-cluster"
  name          = "polaris-db"
  namespace     = local.ns.database
  image         = module.versions.images["postgresql"].ref
  instances     = coalesce(var.postgres_instances, var.ha ? 3 : 1)
  database      = "polaris"
  storage_size  = var.postgres_storage_size
  storage_class = var.storage_class
  resources     = var.postgres_resources
  labels        = local.common_labels
}

module "polaris" {
  source    = "../../modules/polaris"
  namespace = module.ns_catalog.name
  chart     = module.versions.charts["polaris"]
  images = {
    polaris    = module.versions.images["polaris"]
    admin_tool = module.versions.images["polaris-admin-tool"]
    postgres   = module.versions.images["postgresql"]
    python     = module.versions.images["python"]
  }
  replicas  = coalesce(var.polaris_replicas, var.ha ? 2 : 1)
  resources = var.polaris_resources
  database = {
    host    = module.polaris_db.host
    kv_path = module.polaris_db.kv_path
  }
  s3 = {
    endpoint            = local.platform.s3_url
    region              = local.platform.s3_region
    credentials_kv_path = "storage/s3-users/${var.polaris_s3_user}"
  }
  catalogs   = local.catalogs
  principals = var.principals
  openbao    = { url = local.platform.openbao_url, kv_mount = local.platform.kv_mount }
  oidc = var.polaris_oidc_enabled ? {
    issuer                = local.platform.oidc_issuer
    client_id             = "polaris"
    client_secret_kv_path = "identity/oidc-clients/polaris"
  } : null
  service_monitor = var.service_monitors
  ca_bundle_pem   = local.platform_ca_pem
  labels          = local.common_labels
}

module "ingress_polaris" {
  source       = "../../modules/ingress-host"
  name         = "polaris"
  namespace    = module.ns_catalog.name
  host         = "polaris.${var.base_domain}"
  service_name = module.polaris.service
  service_port = 8181
  backend_tls  = { server_name = module.polaris.host }
  labels       = local.common_labels
}
