# 21-query: Trino (coordinator + optional autoscaled workers) and OPA in
# namespace `query`.

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
  trino_labels    = { "app.kubernetes.io/name" = "trino" }
  coordinator     = { "app.kubernetes.io/name" = "trino", "app.kubernetes.io/component" = "coordinator" }
  opa_labels      = { "app.kubernetes.io/name" = "opa" }
}

module "ns_query" {
  source = "../../modules/namespace-baseline"
  name   = local.ns.query
  labels = local.common_labels

  secrets_access           = true
  ca_bundle_pem            = local.platform_ca_pem
  allow_ingress_hosts      = true  # OIDC discovery + Keycloak admin API through the public issuer URL
  allow_same_namespace     = false # OPA may only be queried by the coordinator
  ingress_controller_ports = [8443]

  ingress_rules = [
    { name = "trino-clients", pod_selector = local.coordinator, from_namespaces = var.trino_client_namespaces, ports = [8443] },
    { name = "trino-internal", pod_selector = local.trino_labels, from_namespaces = [local.ns.query], from_pod_labels = local.trino_labels, ports = [8080, 8443] },
    { name = "trino-metrics", pod_selector = local.trino_labels, from_namespaces = var.metrics_namespaces, ports = [5556] },
  ]
  egress_rules = [
    { name = "trino-internal", pod_selector = local.trino_labels, to_namespaces = [local.ns.query], to_pod_labels = local.trino_labels, ports = [8080, 8443] },
    { name = "trino-opa", pod_selector = local.coordinator, to_namespaces = [local.ns.query], to_pod_labels = local.opa_labels, ports = [8181] },
    { name = "polaris", pod_selector = local.trino_labels, to_namespaces = [local.ns.catalog], ports = [8181] },
    { name = "s3", pod_selector = local.trino_labels, to_namespaces = [local.ns.storage], ports = [9000] },
  ]
  resource_quota = var.query_resource_quota
}

module "opa" {
  source                = "../../modules/opa"
  namespace             = module.ns_query.name
  image                 = module.versions.images["opa"].ref
  replicas              = coalesce(var.opa_replicas, var.ha ? 2 : 1)
  bundle_ref            = var.opa_bundle_ref
  registry_ca_pem       = var.registry_ca_pem
  registry_egress_cidrs = var.registry_cidrs
  registry_port         = tonumber(element(concat(regexall(":([0-9]+)$", var.registry_host)[*][0], ["443"]), 0))
  client_pod_labels     = local.coordinator
  metrics_namespaces    = var.metrics_namespaces
  labels                = local.common_labels
}

module "trino" {
  source      = "../../modules/trino"
  namespace   = module.ns_query.name
  chart       = module.versions.charts["trino"]
  environment = replace(var.environment, "-", "_")
  images = {
    trino        = module.versions.images["trino"]
    python       = module.versions.images["python"]
    jmx_exporter = module.versions.images["jmx-exporter"]
  }
  workers            = coalesce(var.trino_workers, var.ha ? 2 : 0)
  worker_autoscaling = var.trino_worker_autoscaling
  coordinator        = var.trino_coordinator
  worker             = var.trino_worker

  catalogs = { for layer in var.layers : layer => layer }
  polaris = {
    uri                 = "https://polaris.${local.ns.catalog}.svc:8181/api/catalog"
    credentials_kv_path = "catalog/polaris/principals/trino"
  }
  s3 = {
    endpoint            = local.platform.s3_url
    region              = local.platform.s3_region
    credentials_kv_path = "storage/s3-users/${var.trino_s3_user}"
  }
  oidc = {
    issuer                = local.platform.oidc_issuer
    client_id             = "trino"
    client_secret_kv_path = "identity/oidc-clients/trino"
  }
  service_accounts = var.trino_service_accounts
  group_sync = {
    keycloak_url          = local.platform.keycloak_url
    realm                 = "lakehouse"
    client_id             = "trino-group-sync"
    client_secret_kv_path = "identity/oidc-clients/trino-group-sync"
  }
  opa_url         = module.opa.url
  service_monitor = var.service_monitors
  jmx_exporter    = var.trino_jmx_exporter
  ca_bundle_pem   = local.platform_ca_pem
  labels          = local.common_labels
}

module "ingress_trino" {
  source       = "../../modules/ingress-host"
  name         = "trino"
  namespace    = module.ns_query.name
  host         = "trino.${var.base_domain}"
  service_name = module.trino.service
  service_port = 8443
  backend_tls  = { server_name = module.trino.host }
  labels       = local.common_labels
}
