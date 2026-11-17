# Off-site copy: one-way `rc mirror` of buckets to a second S3 target, one
# sub-path per source bucket. Per bucket: propagate_deletes (rc mirror
# --remove) for data that must be erasable (lake buckets), no propagation for
# backups (the target should have versioning + object lock so that a
# compromised platform cannot destroy them).

locals {
  labels = merge(var.labels, { "app.kubernetes.io/name" = var.name, "app.kubernetes.io/component" = "backup" })
  dst    = trim("${var.target_s3.bucket}/${var.target_s3.prefix}", "/")
  plain_env = {
    SSL_CERT_FILE = "/etc/platform-ca/ca.crt"
    HOME          = "/tmp"
    SRC_SCHEME    = split("://", var.source_s3.endpoint)[0]
    SRC_HOST      = split("://", var.source_s3.endpoint)[1]
    DST_SCHEME    = split("://", var.target_s3.endpoint)[0]
    DST_HOST      = split("://", var.target_s3.endpoint)[1]
  }
  secret_env = {
    SRC_ACCESS_KEY = [var.source_s3.credentials_secret, "access_key_id"]
    SRC_SECRET_KEY = [var.source_s3.credentials_secret, "secret_access_key"]
    DST_ACCESS_KEY = [var.target_s3.credentials_secret, "access_key_id"]
    DST_SECRET_KEY = [var.target_s3.credentials_secret, "secret_access_key"]
  }
}

resource "kubernetes_config_map_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "mirror.sh" = <<-SH
      set -eu
      export RC_HOST_src="$${SRC_SCHEME}://$${SRC_ACCESS_KEY}:$${SRC_SECRET_KEY}@$${SRC_HOST}"
      export RC_HOST_dst="$${DST_SCHEME}://$${DST_ACCESS_KEY}:$${DST_SECRET_KEY}@$${DST_HOST}"
      rc_status=0
      %{for b in var.source_s3.buckets~}
      echo "== ${b.name}"
      rc mirror --summary --retry-attempts 5 %{if b.propagate_deletes}--remove %{endif}"src/${b.name}" "dst/${local.dst}/${b.name}" || rc_status=1
      %{endfor~}
      exit $rc_status
    SH
  }
}

resource "kubernetes_cron_job_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    schedule                      = var.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = local.labels
          }
          spec {
            automount_service_account_token = false
            restart_policy                  = "Never"
            security_context {
              run_as_non_root = true
              run_as_user     = 65534
              run_as_group    = 65534
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }
            container {
              name    = "mirror"
              image   = var.image
              command = ["sh", "/config/mirror.sh"]
              dynamic "env" {
                for_each = local.plain_env
                content {
                  name  = env.key
                  value = env.value
                }
              }
              dynamic "env" {
                for_each = local.secret_env
                content {
                  name = env.key
                  value_from {
                    secret_key_ref {
                      name = env.value[0]
                      key  = env.value[1]
                    }
                  }
                }
              }
              resources {
                requests = var.resources.requests
                limits   = var.resources.limits
              }
              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                run_as_non_root            = true
                capabilities {
                  drop = ["ALL"]
                }
              }
              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
              volume_mount {
                name       = "config"
                mount_path = "/config"
              }
              volume_mount {
                name       = "platform-ca"
                mount_path = "/etc/platform-ca"
              }
            }
            volume {
              name = "tmp"
              empty_dir {
                size_limit = "256Mi"
              }
            }
            volume {
              name = "config"
              config_map {
                name = kubernetes_config_map_v1.this.metadata[0].name
              }
            }
            volume {
              name = "platform-ca"
              config_map {
                name = var.ca_configmap
              }
            }
          }
        }
      }
    }
  }
}
