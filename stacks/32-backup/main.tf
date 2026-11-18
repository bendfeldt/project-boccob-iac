# 32-backup: backups that are not part of a component's own definition.
#   - OpenBao raft snapshots -> s3://platform-backup/openbao/ (CronJob)
#   - retention: S3 lifecycle on platform-backup (snapshots + noncurrent versions)
#   - off-site copy of platform-backup to a second S3 target (optional)
# PostgreSQL backups (base backup + WAL, PITR) are configured on each
# CloudNativePG cluster (modules/postgres-cluster `backup`, local.postgres_backup
# in stack 12). k3s etcd snapshots: scripts/lib/k3s-config.sh (HA servers).
# Scripts: scripts/backup/*.sh, `make backup|restore|restore-test`.

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
  ns_backup = "backup"
  s3_port   = tonumber(split(":", local.platform.s3_url)[2])
  # rc lifecycle JSON (rc bucket lifecycle rule export format); import replaces
  # the bucket's whole lifecycle configuration on every run
  lifecycle = {
    rules = [
      {
        id         = "openbao-snapshots"
        status     = "Enabled"
        prefix     = "openbao/"
        expiration = { days = var.openbao_snapshot_retention_days }
      },
      {
        id                          = "noncurrent-versions"
        status                      = "Enabled"
        noncurrentVersionExpiration = { noncurrentDays = var.noncurrent_version_retention_days }
      },
    ]
  }
}

module "ns_backup" {
  source = "../../modules/namespace-baseline"
  name   = local.ns_backup
  labels = local.common_labels

  secrets_access = true
  ca_bundle_pem  = data.kubernetes_config_map_v1.platform_ca.data["ca.crt"]
  egress_rules = concat(
    [
      { name = "openbao", to_namespaces = [local.platform.namespaces.secrets], ports = [8200] },
      { name = "s3", to_namespaces = [local.platform.namespaces.storage], ports = [local.s3_port] },
      # restore test: verify a restored database from a short-lived pod
      { name = "postgres", to_namespaces = [local.platform.namespaces.database], ports = [5432] },
    ],
    var.offsite == null ? [] : [{
      name          = "offsite"
      to_cidrs      = var.offsite.cidrs
      to_namespaces = var.offsite.namespaces
      ports         = [var.offsite.port]
    }],
  )
  resource_quota = {
    "requests.memory" = "1Gi"
    "limits.memory"   = "2Gi"
    "pods"            = "10"
  }
}

# S3 user platform-backup (rw platform-backup), mapped to the AWS-style keys
module "backup_s3_credentials" {
  source     = "../../modules/external-secret"
  store      = module.ns_backup.secret_stores.read
  store_kind = module.ns_backup.secret_stores.kind
  name       = "platform-backup-s3"
  namespace  = module.ns_backup.name
  kv_path    = "storage/s3-users/platform-backup"
  template = {
    access_key_id     = "{{ index . \"access-key\" }}"
    secret_access_key = "{{ index . \"secret-key\" }}"
  }
  labels = local.common_labels
}

# =============================================================================
# OpenBao raft snapshots
# =============================================================================
resource "vault_policy" "raft_snapshot" {
  name   = "raft-snapshot"
  policy = <<-EOT
    path "sys/storage/raft/snapshot" { capabilities = ["read"] }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "raft_snapshot" {
  backend                          = "kubernetes"
  role_name                        = "raft-snapshot"
  bound_service_account_names      = [module.openbao_snapshot.service_account]
  bound_service_account_namespaces = [module.ns_backup.name]
  audience                         = "openbao"
  token_policies                   = [vault_policy.raft_snapshot.name]
  token_ttl                        = 600
  token_max_ttl                    = 900
}

module "openbao_snapshot" {
  source    = "../../modules/openbao-snapshot"
  namespace = module.ns_backup.name
  images = {
    openbao = module.versions.images["openbao"].ref
    rc      = module.versions.images["rustfs-rc"].ref
  }
  schedule     = var.openbao_snapshot_schedule
  openbao_addr = local.platform.openbao_url
  openbao_role = "raft-snapshot"
  s3 = {
    endpoint           = local.platform.s3_url
    bucket             = "platform-backup"
    prefix             = "openbao"
    credentials_secret = module.backup_s3_credentials.secret_name
  }
  lifecycle_rules = local.lifecycle
  resources       = coalesce(var.resources, { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "256Mi" } })
  labels          = local.common_labels
}

# =============================================================================
# Off-site copy (optional)
# =============================================================================
module "offsite_s3_credentials" {
  count      = var.offsite == null ? 0 : 1
  source     = "../../modules/external-secret"
  store      = module.ns_backup.secret_stores.read
  store_kind = module.ns_backup.secret_stores.kind
  name       = "offsite-s3"
  namespace  = module.ns_backup.name
  kv_path    = var.offsite.credentials
  template = {
    access_key_id     = "{{ index . \"access-key\" }}"
    secret_access_key = "{{ index . \"secret-key\" }}"
  }
  labels = local.common_labels
}

module "offsite_copy" {
  count     = var.offsite == null ? 0 : 1
  source    = "../../modules/s3-mirror"
  name      = "offsite-copy"
  namespace = module.ns_backup.name
  image     = module.versions.images["rustfs-rc"].ref
  schedule  = var.offsite.schedule
  source_s3 = {
    endpoint           = local.platform.s3_url
    credentials_secret = module.backup_s3_credentials.secret_name
    buckets            = var.offsite.buckets
  }
  target_s3 = {
    endpoint           = var.offsite.endpoint
    bucket             = var.offsite.bucket
    prefix             = var.offsite.prefix
    credentials_secret = module.offsite_s3_credentials[0].secret_name
  }
  labels = local.common_labels
}
