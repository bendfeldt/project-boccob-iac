# Scheduled OpenBao raft snapshot to S3.
#   container "snapshot" (bao CLI): kubernetes auth login with a short-lived
#     projected token -> `bao operator raft snapshot save`
#   container "upload" (rc): waits for the snapshot, uploads it with SSE-S3,
#     imports the lifecycle (retention) rules
# Two regular containers instead of init container + container: the k3s
# NetworkPolicy controller did not let an init container through the egress
# allows of the namespace (connection refused; observed on dev).
# The snapshot holds barrier-encrypted data only: restoring it needs the unseal
# keys (key custody), so a leaked snapshot does not expose secrets by itself.

locals {
  labels = merge(var.labels, { "app.kubernetes.io/name" = var.name, "app.kubernetes.io/component" = "backup" })
  security_context = {
    allow_privilege_escalation = false
    read_only_root_filesystem  = true
    run_as_non_root            = true
  }
}

resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  automount_service_account_token = false
}

resource "kubernetes_config_map_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "snapshot.sh"    = <<-SH
      set -eu
      trap '[ -f /work/done ] || echo failed > /work/failed' EXIT
      # NetworkPolicy allows for a new pod can take a few seconds to be programmed
      i=0
      until token="$(bao write -field=token auth/kubernetes/login role="$OPENBAO_ROLE" jwt=@/var/run/secrets/openbao/token)"; do
        i=$((i + 1)); [ "$i" -lt 30 ] || exit 1
        sleep 2
      done
      BAO_TOKEN="$token" bao operator raft snapshot save /work/openbao.snap
      BAO_TOKEN="$token" bao token revoke -self >/dev/null
      sha256sum /work/openbao.snap | cut -d' ' -f1 > /work/openbao.snap.sha256
      echo "snapshot: $(wc -c < /work/openbao.snap) bytes, sha256 $(cat /work/openbao.snap.sha256)"
      touch /work/done
    SH
    "upload.sh"      = <<-SH
      set -eu
      i=0
      until [ -f /work/done ]; do
        [ -f /work/failed ] && { echo "snapshot failed"; exit 1; }
        i=$((i + 1)); [ "$i" -lt 300 ] || { echo "timeout waiting for the snapshot"; exit 1; }
        sleep 2
      done
      export RC_HOST_target="$${S3_SCHEME}://$${AWS_ACCESS_KEY_ID}:$${AWS_SECRET_ACCESS_KEY}@$${S3_HOST}"
      ts="$(date -u +%Y%m%dT%H%M%SZ)"
      dest="target/$${S3_BUCKET}/$${S3_PREFIX}/raft-$${ts}.snap"
      # SSE-S3 is requested per destination object (rc wants the exact path)
      for f in openbao.snap openbao.snap.sha256; do
        target="$dest$${f#openbao.snap}"
        if [ "$S3_ENCRYPT" = "true" ]; then
          rc put --quiet --enc-s3 "$target" "/work/$f" "$target"
        else
          rc put --quiet "/work/$f" "$target"
        fi
      done
      echo "uploaded $dest"
      if [ -f /config/lifecycle.json ]; then
        rc bucket lifecycle rule import "target/$${S3_BUCKET}" /config/lifecycle.json >/dev/null
        echo "lifecycle rules applied to $${S3_BUCKET}"
      fi
    SH
    "lifecycle.json" = var.lifecycle_rules == null ? "" : jsonencode(var.lifecycle_rules)
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
    successful_jobs_history_limit = var.history
    failed_jobs_history_limit     = var.history
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
            service_account_name            = kubernetes_service_account_v1.this.metadata[0].name
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
              name    = "snapshot"
              image   = var.images.openbao
              command = ["sh", "/config/snapshot.sh"]
              env {
                name  = "BAO_ADDR"
                value = var.openbao_addr
              }
              env {
                name  = "BAO_CACERT"
                value = "/etc/platform-ca/ca.crt"
              }
              env {
                name  = "OPENBAO_ROLE"
                value = var.openbao_role
              }
              env {
                name  = "HOME"
                value = "/tmp"
              }
              resources {
                requests = var.resources.requests
                limits   = var.resources.limits
              }
              security_context {
                allow_privilege_escalation = local.security_context.allow_privilege_escalation
                read_only_root_filesystem  = local.security_context.read_only_root_filesystem
                run_as_non_root            = local.security_context.run_as_non_root
                capabilities {
                  drop = ["ALL"]
                }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
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
              volume_mount {
                name       = "token"
                mount_path = "/var/run/secrets/openbao"
              }
            }
            container {
              name    = "upload"
              image   = var.images.rc
              command = ["sh", "/config/upload.sh"]
              env {
                name  = "SSL_CERT_FILE"
                value = "/etc/platform-ca/ca.crt"
              }
              env {
                name  = "HOME"
                value = "/tmp"
              }
              env {
                name  = "S3_SCHEME"
                value = split("://", var.s3.endpoint)[0]
              }
              env {
                name  = "S3_HOST"
                value = split("://", var.s3.endpoint)[1]
              }
              env {
                name  = "S3_BUCKET"
                value = var.s3.bucket
              }
              env {
                name  = "S3_PREFIX"
                value = var.s3.prefix
              }
              env {
                name  = "S3_ENCRYPT"
                value = tostring(var.s3.encrypt)
              }
              env {
                name = "AWS_ACCESS_KEY_ID"
                value_from {
                  secret_key_ref {
                    name = var.s3.credentials_secret
                    key  = "access_key_id"
                  }
                }
              }
              env {
                name = "AWS_SECRET_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = var.s3.credentials_secret
                    key  = "secret_access_key"
                  }
                }
              }
              resources {
                requests = var.resources.requests
                limits   = var.resources.limits
              }
              security_context {
                allow_privilege_escalation = local.security_context.allow_privilege_escalation
                read_only_root_filesystem  = local.security_context.read_only_root_filesystem
                run_as_non_root            = local.security_context.run_as_non_root
                capabilities {
                  drop = ["ALL"]
                }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
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
              name = "work"
              empty_dir {
                size_limit = "512Mi"
              }
            }
            volume {
              name = "tmp"
              empty_dir {
                size_limit = "64Mi"
              }
            }
            volume {
              name = "config"
              config_map {
                name = kubernetes_config_map_v1.this.metadata[0].name
                items {
                  key  = "snapshot.sh"
                  path = "snapshot.sh"
                }
                items {
                  key  = "upload.sh"
                  path = "upload.sh"
                }
                dynamic "items" {
                  for_each = var.lifecycle_rules == null ? [] : [1]
                  content {
                    key  = "lifecycle.json"
                    path = "lifecycle.json"
                  }
                }
              }
            }
            volume {
              name = "platform-ca"
              config_map {
                name = var.ca_configmap
              }
            }
            volume {
              name = "token"
              projected {
                sources {
                  service_account_token {
                    audience           = var.openbao_audience
                    expiration_seconds = 600
                    path               = "token"
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
