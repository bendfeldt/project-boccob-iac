locals {
  name        = "rustfs"
  service     = "${local.name}-svc"
  tls_name    = "${local.name}-server-tls"
  root_secret = "${local.name}-root"
  endpoint    = "https://${local.service}.${var.namespace}.svc:9000"

  security_context_pod = {
    runAsNonRoot   = true
    runAsUser      = 10001
    runAsGroup     = 10001
    fsGroup        = 10001
    seccompProfile = { type = "RuntimeDefault" }
  }
  security_context_container = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    runAsNonRoot             = true
    capabilities             = { drop = ["ALL"] }
    seccompProfile           = { type = "RuntimeDefault" }
  }
}

# --- root credentials: generated in-cluster, stored in OpenBao -----------------------
module "root_credentials" {
  source    = "../generated-secret"
  name      = local.root_secret
  namespace = var.namespace
  kv_path   = "${var.namespace}/rustfs-root"
  keys      = ["RUSTFS_ACCESS_KEY", "RUSTFS_SECRET_KEY"]
  length    = 32
  labels    = var.labels
}

module "user_credentials" {
  for_each  = var.users
  source    = "../generated-secret"
  name      = "s3-user-${each.key}"
  namespace = var.namespace
  kv_path   = "${var.namespace}/s3-users/${each.key}"
  keys      = ["secret-key"]
  literals  = { "access-key" = each.key }
  length    = 40
  labels    = var.labels
}

# --- TLS ---------------------------------------------------------------------------
resource "kubernetes_manifest" "server_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.tls_name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      secretName  = local.tls_name
      commonName  = "${local.service}.${var.namespace}.svc"
      duration    = "2160h0m0s"
      renewBefore = "720h0m0s"
      # RSA: widest compatibility with S3 SDKs / JVM clients
      privateKey = { algorithm = "RSA", size = 2048, rotationPolicy = "Always" }
      usages     = ["server auth", "client auth"]
      dnsNames = [
        "${local.service}.${var.namespace}.svc",
        "${local.service}.${var.namespace}.svc.cluster.local",
        "*.${local.name}-headless.${var.namespace}.svc.cluster.local",
        "*.${local.name}-headless.${var.namespace}.svc",
        "localhost",
      ]
      ipAddresses = ["127.0.0.1"]
      issuerRef   = { group = "cert-manager.io", kind = "ClusterIssuer", name = var.cluster_issuer }
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

# --- RustFS ------------------------------------------------------------------------
resource "helm_release" "this" {
  name       = local.name
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 900
  atomic     = true

  values = [yamlencode({
    fullnameOverride = local.name
    mode = {
      standalone  = { enabled = !var.distributed }
      distributed = { enabled = var.distributed }
    }
    replicaCount  = var.distributed ? var.replicas : 1
    drivesPerNode = var.distributed ? var.drives_per_node : null
    image = {
      rustfs    = { repository = var.images["rustfs"].repository, tag = var.images["rustfs"].tag_digest }
      initImage = { repository = var.images["init"].repository, tag = var.images["init"].tag_digest }
    }
    secret = { existingSecret = module.root_credentials.secret_name }
    # the Secret only carries credentials: let the chart inject the pod endpoint identity
    localEndpointHost = { autoInject = var.distributed ? true : null }
    config = {
      rustfs = {
        region            = var.region
        console_enable    = "true"
        obs_environment   = "production"
        obs_log_directory = "" # log to stdout, no log volume
        log_level         = "info"
      }
    }
    tls = {
      enabled        = true
      existingSecret = local.tls_name
      trustSecret    = local.tls_name
    }
    ingress                  = { enabled = false }
    podSecurityContext       = local.security_context_pod
    containerSecurityContext = local.security_context_container
    serviceAccount           = { create = true, automount = false }
    resources                = var.resources
    storageclass = {
      name            = var.storage_class
      dataStorageSize = var.data_storage_size
    }
    pdb          = { create = var.distributed, maxUnavailable = 1 }
    affinity     = { podAntiAffinity = { enabled = var.distributed, topologyKey = "kubernetes.io/hostname" } }
    commonLabels = var.labels
  })]

  depends_on = [kubernetes_manifest.server_cert]
}

# --- buckets, users, policies (idempotent Job, re-run when the definition changes) --
locals {
  user_policies = {
    for name, user in var.users : name => jsonencode({
      Version = "2012-10-17"
      Statement = concat(
        length(user.read_write_buckets) == 0 ? [] : [{
          Effect   = "Allow"
          Action   = ["s3:*"]
          Resource = flatten([for b in user.read_write_buckets : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
        }],
        length(user.read_only_buckets) == 0 ? [] : [{
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket", "s3:ListBucketVersions", "s3:GetBucketLocation"]
          Resource = flatten([for b in user.read_only_buckets : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
        }],
      )
    })
  }

  provision_script = <<-SH
    set -eu
    export RC_HOST_platform="https://$${RUSTFS_ACCESS_KEY}:$${RUSTFS_SECRET_KEY}@${local.service}.${var.namespace}.svc:9000"
    echo "waiting for RustFS"
    i=0
    until rc bucket list platform/ >/dev/null 2>&1; do
      i=$((i + 1)); [ "$i" -lt 60 ] || { echo "RustFS not reachable"; rc bucket list platform/; exit 1; }
      sleep 5
    done
    %{for bucket, cfg in var.buckets~}
    rc bucket create "platform/${bucket}" --ignore-existing
    %{if cfg.versioning~}
    rc bucket version enable "platform/${bucket}"
    %{endif~}
    %{endfor~}
    %{for name, user in var.users~}
    rc admin policy create platform/ "${name}" "/config/policy-${name}.json"
    rc admin user add platform/ "${name}" "$${S3_USER_SECRET_${upper(replace(name, "-", "_"))}}"
    rc admin policy attach platform/ "${name}" --user "${name}"
    %{endfor~}
    echo "buckets:"
    rc bucket list platform/
  SH

  provision_hash = substr(sha256(join("\n", [local.provision_script, jsonencode(local.user_policies), var.images["rc"].ref])), 0, 10)
}

resource "kubernetes_config_map_v1" "provision" {
  metadata {
    name      = "${local.name}-provision"
    namespace = var.namespace
    labels    = var.labels
  }
  data = merge(
    { "provision.sh" = local.provision_script },
    { for name, policy in local.user_policies : "policy-${name}.json" => policy },
  )
}

resource "kubernetes_job_v1" "provision" {
  metadata {
    name      = "${local.name}-provision-${local.provision_hash}"
    namespace = var.namespace
    labels    = var.labels
  }
  spec {
    backoff_limit = 4
    template {
      metadata {
        labels = merge(var.labels, { "app.kubernetes.io/name" = "rustfs-provision" })
      }
      spec {
        restart_policy                  = "OnFailure"
        automount_service_account_token = false
        security_context {
          run_as_non_root = true
          run_as_user     = 100
          run_as_group    = 101
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name    = "rc"
          image   = var.images["rc"].ref
          command = ["sh", "/config/provision.sh"]
          env {
            name  = "HOME"
            value = "/tmp"
          }
          env {
            name  = "SSL_CERT_FILE"
            value = "/etc/platform-ca/ca.crt"
          }
          env_from {
            secret_ref {
              name = module.root_credentials.secret_name
            }
          }
          dynamic "env" {
            for_each = var.users
            content {
              name = "S3_USER_SECRET_${upper(replace(env.key, "-", "_"))}"
              value_from {
                secret_key_ref {
                  name = module.user_credentials[env.key].secret_name
                  key  = "secret-key"
                }
              }
            }
          }
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "ca"
            mount_path = "/etc/platform-ca"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.provision.metadata[0].name
          }
        }
        volume {
          name = "ca"
          config_map {
            name = var.ca_configmap
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
  depends_on = [helm_release.this]
}
