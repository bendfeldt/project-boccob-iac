# 22-orchestration: Dagster (webserver, daemon, solution code location,
# K8sRunLauncher) with its own PostgreSQL database, behind oauth2-proxy.

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
  # continuous backup to s3://platform-backup/postgres/<cluster> (ops work
  # package, stack 32-backup): credentials + CA Secret are created by stack 12
  postgres_backup = var.postgres_backup == null ? null : {
    destination_path   = "s3://platform-backup/postgres"
    endpoint_url       = local.platform.s3_url
    credentials_secret = "platform-backup-s3"
    ca_secret          = "platform-ca"
    retention_policy   = var.postgres_backup.retention_policy
    schedule           = var.postgres_backup.schedule
    encryption         = var.postgres_backup.encryption
  }
  ns              = local.platform.namespaces
  platform_ca_pem = data.kubernetes_config_map_v1.platform_ca.data["ca.crt"]
  auth_labels     = { "app.kubernetes.io/name" = "dagster-auth" }
  webserver       = { "component" = "dagster-webserver" }
  code_server     = { "component" = "user-deployments" }
}

module "ns_orchestration" {
  source = "../../modules/namespace-baseline"
  name   = local.ns.orchestration
  labels = local.common_labels

  secrets_access           = true
  ca_bundle_pem            = local.platform_ca_pem
  allow_kube_api           = true # K8sRunLauncher creates Jobs
  allow_ingress_hosts      = true # oauth2-proxy -> Keycloak issuer; run pods -> Trino through Traefik
  ingress_controller_ports = [8443]
  # explicit flows only: the webserver has no authentication of its own
  allow_same_namespace = false

  ingress_rules = [
    { name = "code-server", pod_selector = local.code_server, from_namespaces = [local.ns.orchestration], from_pod_labels = { "app.kubernetes.io/name" = "dagster" }, ports = [4000] },
    { name = "webserver", pod_selector = local.webserver, from_namespaces = [local.ns.orchestration], from_pod_labels = local.auth_labels, ports = [80] },
  ]
  egress_rules = [
    { name = "code-server", pod_selector = { "app.kubernetes.io/name" = "dagster" }, to_namespaces = [local.ns.orchestration], to_pod_labels = local.code_server, ports = [4000] },
    { name = "webserver", pod_selector = local.auth_labels, to_namespaces = [local.ns.orchestration], to_pod_labels = local.webserver, ports = [80] },
    { name = "postgres", to_namespaces = [local.ns.database], ports = [5432] },
    { name = "polaris", to_namespaces = [local.ns.catalog], ports = [8181] },
    { name = "s3", to_namespaces = [local.ns.storage], ports = [9000] },
    # pepper Job: create-only write to OpenBao
    { name = "openbao", to_namespaces = [local.ns.secrets], ports = [8200] },
  ]
  resource_quota = var.orchestration_resource_quota
}

module "dagster_db" {
  source        = "../../modules/postgres-cluster"
  push_store    = "openbao-push"
  store_kind    = "SecretStore" # namespace database (stack 12)
  name          = "dagster-db"
  namespace     = local.ns.database
  image         = module.versions.images["postgresql"].ref
  instances     = coalesce(var.postgres_instances, var.ha ? 3 : 1)
  backup        = local.postgres_backup
  database      = "dagster"
  storage_size  = var.postgres_storage_size
  storage_class = var.storage_class
  resources     = var.postgres_resources
  labels        = local.common_labels
}

module "dagster" {
  source        = "../../modules/dagster"
  secret_stores = module.ns_orchestration.secret_stores
  namespace     = module.ns_orchestration.name
  charts = {
    dagster          = module.versions.charts["dagster"]
    user_deployments = module.versions.charts["dagster-user-deployments"]
  }
  code_location_image = var.dagster_code_location_image
  system_image        = module.versions.images["dagster"]
  images = {
    postgres = module.versions.images["postgresql"]
    busybox  = module.versions.images["busybox"]
    python   = module.versions.images["python"]
  }
  database = {
    host    = module.dagster_db.host
    kv_path = module.dagster_db.kv_path
  }
  solution_env = merge({
    S3_ENDPOINT_URL      = local.platform.s3_url
    S3_REGION            = local.platform.s3_region
    RAW_BUCKET           = "lakehouse-raw"
    RAW_INDEX_PREFIX     = "iceberg"
    POLARIS_URI          = "https://polaris.${local.ns.catalog}.svc:8181/api/catalog"
    POLARIS_SCOPE        = "PRINCIPAL_ROLE:ALL"
    RAW_CATALOG          = "raw"
    CLEAN_CATALOG        = "clean"
    CONSOLIDATED_CATALOG = "consolidated"
    CURATED_CATALOG      = "curated"
    # through Traefik, like every other client (audit: X-Forwarded-For only from Traefik)
    TRINO_HOST        = "trino.${var.base_domain}"
    TRINO_PORT        = "443"
    TRINO_HTTP_SCHEME = "https"
    TRINO_USER        = var.trino_service_account
    DBT_TARGET        = "password"
    SCHEDULES_ENABLED = tostring(var.schedules_enabled)
    SCHEDULE_TIMEZONE = "Europe/Copenhagen"
    # object scan after each erasure: scoped (test/prod) | full (dev: whole lake,
    # O(size of the lake)) | false (docs/data-plane.md, "Erasure verification")
    ERASURE_VERIFY_STORAGE = var.erasure_verify_storage
    # dbt --full-refresh of incremental models is refused unless dev (solution docs/releases.md)
    LAKEHOUSE_ENV = var.environment
    # delayed-deletion window: maintenance/retention purge only older noncurrent
    # versions; same value as the bucket lifecycle (common variable)
    NONCURRENT_VERSION_GRACE_DAYS = tostring(var.lakehouse_noncurrent_version_days)
  }, var.solution_env)
  solution_secrets = {
    S3_ACCESS_KEY_ID      = { kv_path = "storage/s3-users/${var.s3_user}", property = "access-key" }
    S3_SECRET_ACCESS_KEY  = { kv_path = "storage/s3-users/${var.s3_user}", property = "secret-key" }
    POLARIS_CLIENT_ID     = { kv_path = "catalog/polaris/principals/${var.polaris_principal}", property = "client-id" }
    POLARIS_CLIENT_SECRET = { kv_path = "catalog/polaris/principals/${var.polaris_principal}", property = "client-secret" }
    TRINO_PASSWORD        = { kv_path = "query/trino/service-accounts/${var.trino_service_account}", property = "password" }
  }
  # the purge credential (s3:DeleteObjectVersion on the lake buckets) is not in
  # lakehouse-env: Secret lakehouse-purge-env (PURGE_CREDENTIALS_SECRET), attached only by
  # the purge_jobs through their dagster-k8s/config tag; admission-guarded (audit N-3)
  job_secrets = {
    purge = {
      env = {
        PURGE_S3_ACCESS_KEY_ID     = { kv_path = "storage/s3-users/${var.purge_s3_user}", property = "access-key" }
        PURGE_S3_SECRET_ACCESS_KEY = { kv_path = "storage/s3-users/${var.purge_s3_user}", property = "secret-key" }
      }
      jobs     = var.purge_jobs
      name_env = "PURGE_CREDENTIALS_SECRET" # read by the solution (orchestration/jobs.py)
    }
  }
  compute_logs = var.compute_logs_s3 ? {
    bucket       = "dagster-compute-logs"
    endpoint_url = local.platform.s3_url
    region       = local.platform.s3_region
    kv_path      = "storage/s3-users/dagster-compute-logs"
  } : null
  openbao             = { url = local.platform.openbao_url, kv_mount = local.platform.kv_mount }
  max_concurrent_runs = var.max_concurrent_runs
  webserver_replicas  = coalesce(var.webserver_replicas, var.ha ? 2 : 1)
  labels              = local.common_labels
}

module "dagster_auth" {
  source         = "../../modules/oauth2-proxy"
  secret_stores  = module.ns_orchestration.secret_stores
  name           = "dagster-auth"
  namespace      = module.ns_orchestration.name
  image          = module.versions.images["oauth2-proxy"].ref
  replicas       = var.ha ? 2 : 1
  public_host    = "dagster.${var.base_domain}"
  public_port    = local.platform.public_port
  upstream       = module.dagster.webserver_url
  oidc           = { issuer = local.platform.oidc_issuer, client_id = "dagster", client_secret_kv_path = "identity/oidc-clients/dagster" }
  allowed_groups = var.dagster_ui_groups
  kv_prefix      = "orchestration/dagster-auth"
  labels         = local.common_labels
}

module "ingress_dagster" {
  source       = "../../modules/ingress-host"
  name         = "dagster"
  namespace    = module.ns_orchestration.name
  host         = "dagster.${var.base_domain}"
  service_name = module.dagster_auth.service
  service_port = 8443
  backend_tls  = { server_name = module.dagster_auth.host }
  labels       = local.common_labels
}
