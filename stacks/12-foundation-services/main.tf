# 12-foundation-services: namespace database (+ backup credentials), RustFS and
# the ingress hosts of the foundation layer. Everything gets its certificates
# from the OpenBao PKI and its credentials through External Secrets.

data "kubernetes_config_map_v1" "platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = local.platform.namespaces.platform
  }
}

locals {
  ns              = local.platform.namespaces
  platform_ca_pem = data.kubernetes_config_map_v1.platform_ca.data["ca.crt"]

  lakehouse_lifecycle = {
    noncurrent_days        = var.lakehouse_noncurrent_version_days
    expired_delete_markers = true
  }
  default_buckets = {
    # versioned for accidental-deletion protection, but deleted/overwritten
    # versions expire quickly so that erasure and retention deletes become
    # final (GDPR art. 17, 5(1)(e)); Iceberg snapshots give the time travel
    "lakehouse-raw"          = { lifecycle = local.lakehouse_lifecycle }
    "lakehouse-clean"        = { lifecycle = local.lakehouse_lifecycle }
    "lakehouse-consolidated" = { lifecycle = local.lakehouse_lifecycle }
    "lakehouse-curated"      = { lifecycle = local.lakehouse_lifecycle }
    "platform-backup"        = {}
    "platform-logs"          = {}
    # WORM archive of the audit trail (object lock, default retention)
    "platform-audit" = { object_lock = var.audit_archive_lock }
  }
  buckets = merge(local.default_buckets, var.buckets)

  default_s3_users = {
    # Polaris / Trino: all Iceberg layers
    "lakehouse-catalog" = { read_write_buckets = ["lakehouse-raw", "lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"] }
    # dlt landing
    "lakehouse-ingest" = { read_write_buckets = ["lakehouse-raw"] }
    # CloudNativePG barman (namespace database) and backup Jobs: own bucket only
    "platform-backup" = { read_write_buckets = ["platform-backup"] }
    # off-site copy of the lake (stack 32-backup): read only, readable only from
    # the backup namespace (stack 11 namespace_secret_stores) - never by the
    # database namespace, whose WAL archiver must not see raw PII (audit N-4)
    "platform-offsite-reader" = { read_only_buckets = ["lakehouse-raw", "lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"] }
    "platform-logs"           = { read_write_buckets = ["platform-logs", "platform-audit"] }
  }
  s3_users = merge(local.default_s3_users, var.s3_users)
}

# =============================================================================
# PostgreSQL (CloudNativePG clusters live in the `database` namespace)
# =============================================================================
module "ns_database" {
  source = "../../modules/namespace-baseline"
  name   = local.ns.database
  labels = local.common_labels

  allow_kube_api = true # CloudNativePG instance manager
  secrets_access = true # push app credentials to OpenBao
  ca_bundle_pem  = local.platform_ca_pem

  ingress_rules = [
    {
      name            = "operator"
      from_namespaces = [local.ns.platform]
      ports           = [8000, 5432]
    },
    {
      name            = "clients"
      from_namespaces = var.postgres_client_namespaces
      ports           = [5432]
    },
    {
      name            = "metrics"
      from_namespaces = var.metrics_namespaces
      ports           = [9187]
    },
  ]
  egress_rules = [
    {
      # WAL archive / base backups to RustFS
      name          = "s3"
      to_namespaces = [local.ns.storage]
      ports         = [9000]
    },
  ]
}

# Backup credentials (S3 user platform-backup) for the CloudNativePG clusters.
# Shared by every cluster in the namespace: pass local.postgres_backup to
# modules/postgres-cluster (see docs/conventions.md, "Add a database").
module "postgres_backup_credentials" {
  source     = "../../modules/external-secret"
  store      = module.ns_database.secret_stores.read
  store_kind = module.ns_database.secret_stores.kind
  name       = "platform-backup-s3"
  namespace  = module.ns_database.name
  kv_path    = "storage/s3-users/platform-backup"
  template = {
    access_key_id     = "{{ index . \"access-key\" }}"
    secret_access_key = "{{ index . \"secret-key\" }}"
  }
  labels     = local.common_labels
  depends_on = [module.rustfs]
}

# CloudNativePG reads the S3 endpoint CA (endpointCA) from a Secret, not from
# the platform-ca ConfigMap. Public material only.
resource "kubernetes_secret_v1" "database_platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = module.ns_database.name
    labels    = local.common_labels
  }
  data = {
    "ca.crt" = local.platform_ca_pem
  }
}

# =============================================================================
# RustFS
# =============================================================================
module "ns_storage" {
  source = "../../modules/namespace-baseline"
  name   = local.ns.storage
  labels = local.common_labels

  secrets_access           = true
  ca_bundle_pem            = local.platform_ca_pem
  ingress_controller_ports = [9000, 9001]

  ingress_rules = [
    {
      name            = "s3-clients"
      from_namespaces = var.s3_client_namespaces
      ports           = [9000]
    },
    {
      name            = "metrics"
      from_namespaces = var.metrics_namespaces
      ports           = [9000]
    },
  ]
  # the largest pod (RustFS) sets its own resources; small defaults for Jobs
  limit_range = {}
}

# SSE-S3 master key: 32 random characters, stored base64-encoded (32 bytes)
module "rustfs_sse" {
  count      = var.rustfs_sse_enabled ? 1 : 0
  source     = "../../modules/generated-secret"
  read_store = module.ns_storage.secret_stores.read
  push_store = module.ns_storage.secret_stores.push
  store_kind = module.ns_storage.secret_stores.kind
  name       = "rustfs-sse"
  namespace  = module.ns_storage.name
  kv_path    = "storage/rustfs-sse"
  keys       = ["seed"]
  length     = 32
  literals   = { "master-key" = "{{ .seed | b64enc }}" }
  labels     = local.common_labels
}

module "rustfs" {
  source        = "../../modules/rustfs"
  secret_stores = module.ns_storage.secret_stores
  namespace     = module.ns_storage.name
  chart         = module.versions.charts["rustfs"]
  images = {
    rustfs = module.versions.images["rustfs"]
    init   = module.versions.images["busybox"]
    rc     = module.versions.images["rustfs-rc"]
  }
  distributed       = coalesce(var.rustfs_distributed, var.ha)
  replicas          = var.rustfs_replicas
  drives_per_node   = var.rustfs_drives_per_node
  data_storage_size = var.rustfs_data_storage_size
  storage_class     = coalesce(var.storage_class, "local-path")
  resources         = var.rustfs_resources
  region            = local.platform.s3_region
  buckets           = local.buckets
  users             = local.s3_users
  sse_master_key_secret = var.rustfs_sse_enabled ? {
    name = module.rustfs_sse[0].secret_name
    key  = "master-key"
  } : null
  labels = local.common_labels
}

module "ingress_s3" {
  source       = "../../modules/ingress-host"
  name         = "s3"
  namespace    = module.ns_storage.name
  host         = "s3.${var.base_domain}"
  service_name = module.rustfs.service
  service_port = 9000
  backend_tls  = { server_name = "${module.rustfs.service}.${local.ns.storage}.svc" }
  labels       = local.common_labels
}

module "ingress_s3_console" {
  source       = "../../modules/ingress-host"
  name         = "s3-console"
  namespace    = module.ns_storage.name
  host         = "s3-console.${var.base_domain}"
  service_name = module.rustfs.service
  service_port = 9001
  # Service annotations (HTTPS backend + ServersTransport) are set by ingress_s3
  labels     = local.common_labels
  depends_on = [module.ingress_s3]
}

# =============================================================================
# OpenBao ingress (namespace `secrets` is owned by 10-foundation-secrets; the
# ingress needs the PKI issuer, so it is created here)
# =============================================================================
resource "kubernetes_config_map_v1" "secrets_platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = local.ns.secrets
    labels    = local.common_labels
  }
  data = {
    "ca.crt" = local.platform_ca_pem
  }
}

module "ingress_openbao" {
  source       = "../../modules/ingress-host"
  name         = "openbao"
  namespace    = local.ns.secrets
  host         = "openbao.${var.base_domain}"
  service_name = "openbao-active"
  service_port = 8200
  backend_tls = {
    server_name  = "openbao.${local.ns.secrets}.svc"
    ca_configmap = kubernetes_config_map_v1.secrets_platform_ca.metadata[0].name
  }
  labels = local.common_labels
}
