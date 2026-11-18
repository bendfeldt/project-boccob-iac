# Dagster OSS (official chart): webserver, daemon (queued run coordinator,
# schedules, sensors), the solution's code location as user deployment and the
# K8sRunLauncher, on its own PostgreSQL database.
#
# Every pod that runs solution code (code server, run pods) gets the same image
# and environment: the user deployment's container context is passed to the
# run launcher (includeConfigInLaunchedRuns).

locals {
  name           = "dagster"
  image_repo     = split("@", var.code_location_image)[0]
  image_digest   = split("@", var.code_location_image)[1]
  code_image     = { repository = local.image_repo, digest = local.image_digest, tag = "", pullPolicy = "IfNotPresent" }
  system_image   = { repository = var.system_image.repository, digest = var.system_image.digest, tag = "", pullPolicy = "IfNotPresent" }
  env_secret     = "${var.code_location_name}-env"
  pg_secret      = "${local.name}-postgresql"
  ca_path        = "/etc/platform-ca/ca.crt"
  pepper_job_sa  = "${local.name}-pepper"
  pools_hash     = substr(sha256(jsonencode(var.pools)), 0, 10)
  pepper_hash    = substr(sha256(join("\n", [file("${path.module}/files/pepper.py"), var.pepper_kv_path, var.images["python"].ref])), 0, 10)
  pod_secctx     = { runAsNonRoot = true, runAsUser = 10001, runAsGroup = 10001, fsGroup = 10001, seccompProfile = { type = "RuntimeDefault" } }
  container_sctx = { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, runAsNonRoot = true, runAsUser = 10001, runAsGroup = 10001, capabilities = { drop = ["ALL"] }, seccompProfile = { type = "RuntimeDefault" } }

  volumes = [
    { name = "platform-ca", configMap = { name = var.ca_configmap } },
    { name = "tmp", emptyDir = {} },
  ]
  volume_mounts = [
    { name = "platform-ca", mountPath = "/etc/platform-ca", readOnly = true },
    { name = "tmp", mountPath = "/tmp" },
  ]
  tls_env = {
    TRINO_CA_BUNDLE     = local.ca_path
    LAKEHOUSE_CA_BUNDLE = local.ca_path
    SSL_CERT_FILE       = local.ca_path
    REQUESTS_CA_BUNDLE  = local.ca_path
    AWS_CA_BUNDLE       = local.ca_path
  }
  env_list = [for k, v in merge(local.tls_env, var.solution_env) : { name = k, value = v }]

  code_location = {
    name               = var.code_location_name
    image              = local.code_image
    dagsterApiGrpcArgs = ["--module-name", var.code_location_module]
    port               = 4000
    env                = local.env_list
    envSecrets         = [{ name = local.env_secret }]
    # run pods inherit these: writable $DAGSTER_HOME (op outputs of the default
    # fs IO manager in storage/, history/), the root filesystem is read-only
    volumes                     = concat(local.volumes, [{ name = "dagster-home", emptyDir = {} }])
    volumeMounts                = concat(local.volume_mounts, [{ name = "dagster-home", mountPath = "/opt/dagster/dagster_home" }])
    includeConfigInLaunchedRuns = { enabled = true }
    podSecurityContext          = local.pod_secctx
    securityContext             = local.container_sctx
    resources                   = var.resources["code_location"]
    labels                      = var.labels
  }
}

# --- secrets ---------------------------------------------------------------------------
module "db_credentials" {
  source     = "../external-secret"
  store      = var.secret_stores.read
  store_kind = var.secret_stores.kind
  name       = local.pg_secret
  namespace  = var.namespace
  kv_path    = var.database.kv_path
  template   = { "postgresql-password" = "{{ .password }}" }
  labels     = var.labels
}

# pepper: created once in OpenBao by a Job (never by OpenTofu, never overwritten)
resource "kubernetes_service_account_v1" "pepper" {
  metadata {
    name      = local.pepper_job_sa
    namespace = var.namespace
    labels    = var.labels
  }
  automount_service_account_token = false
}

resource "vault_policy" "pepper" {
  name   = "${var.namespace}-${local.pepper_job_sa}"
  policy = <<-HCL
    # create only: an existing pepper can never be replaced by this identity
    path "${var.openbao.kv_mount}/data/${var.pepper_kv_path}" {
      capabilities = ["create"]
    }
    path "${var.openbao.kv_mount}/metadata/${var.pepper_kv_path}" {
      capabilities = ["read"]
    }
  HCL
}

resource "vault_kubernetes_auth_backend_role" "pepper" {
  backend                          = var.openbao.auth_backend
  role_name                        = "${var.namespace}-${local.pepper_job_sa}"
  bound_service_account_names      = [kubernetes_service_account_v1.pepper.metadata[0].name]
  bound_service_account_namespaces = [var.namespace]
  token_policies                   = [vault_policy.pepper.name]
  token_ttl                        = 300
  token_max_ttl                    = 600
}

resource "kubernetes_config_map_v1" "jobs" {
  metadata {
    name      = "${local.name}-platform-jobs"
    namespace = var.namespace
    labels    = var.labels
  }
  data = {
    "pepper.py" = file("${path.module}/files/pepper.py")
  }
}

resource "kubernetes_job_v1" "pepper" {
  metadata {
    name      = "${local.name}-pepper-${local.pepper_hash}"
    namespace = var.namespace
    labels    = var.labels
  }
  spec {
    backoff_limit = 4
    template {
      metadata {
        labels = merge(var.labels, { "app.kubernetes.io/name" = "dagster-pepper" })
      }
      spec {
        restart_policy                  = "OnFailure"
        service_account_name            = kubernetes_service_account_v1.pepper.metadata[0].name
        automount_service_account_token = true
        enable_service_links            = false
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name    = "pepper"
          image   = var.images["python"].ref
          command = ["python", "-I", "/jobs/pepper.py"]
          env {
            name  = "OPENBAO_URL"
            value = var.openbao.url
          }
          env {
            name  = "OPENBAO_ROLE"
            value = vault_kubernetes_auth_backend_role.pepper.role_name
          }
          env {
            name  = "OPENBAO_KV_MOUNT"
            value = var.openbao.kv_mount
          }
          env {
            name  = "PEPPER_KV_PATH"
            value = var.pepper_kv_path
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
            requests = { cpu = "5m", memory = "32Mi" }
            limits   = { memory = "96Mi" }
          }
          volume_mount {
            name       = "jobs"
            mount_path = "/jobs"
            read_only  = true
          }
          volume_mount {
            name       = "ca"
            mount_path = "/etc/platform-ca"
            read_only  = true
          }
        }
        volume {
          name = "jobs"
          config_map {
            name = kubernetes_config_map_v1.jobs.metadata[0].name
          }
        }
        volume {
          name = "ca"
          config_map {
            name = var.ca_configmap
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "5m"
    update = "5m"
  }
}

# all secret variables of the platform contract in one Secret
resource "kubernetes_manifest" "solution_env" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.env_secret
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      refreshInterval = "5m0s"
      secretStoreRef  = { name = var.secret_stores.read, kind = var.secret_stores.kind }
      target          = { name = local.env_secret, creationPolicy = "Owner", deletionPolicy = "Retain" }
      data = [
        for env_name, ref in merge(var.solution_secrets, { PSEUDONYM_PEPPER = { kv_path = var.pepper_kv_path, property = "pepper" } }) : {
          secretKey = env_name
          remoteRef = { key = ref.kv_path, property = ref.property }
        }
      ]
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
    update = "3m"
  }
  depends_on = [kubernetes_job_v1.pepper]
}

# --- Dagster ---------------------------------------------------------------------------
resource "helm_release" "this" {
  name       = local.name
  namespace  = var.namespace
  repository = var.charts["dagster"].repository
  chart      = var.charts["dagster"].name
  version    = var.charts["dagster"].version
  timeout    = 900
  atomic     = true

  values = [yamlencode({
    fullnameOverride = local.name
    global = {
      postgresqlSecretName = module.db_credentials.secret_name
      dagsterHome          = "/opt/dagster/dagster_home"
    }
    generatePostgresqlPasswordSecret = false
    generateCeleryConfigSecret       = false
    telemetry                        = { enabled = false }

    postgresql = {
      enabled            = false
      postgresqlHost     = var.database.host
      postgresqlUsername = "dagster"
      postgresqlDatabase = "dagster"
      postgresqlParams   = { sslmode = "verify-full", sslrootcert = local.ca_path }
      service            = { port = var.database.port }
      image = {
        registry   = var.images["postgres"].registry
        repository = var.images["postgres"].repository_path
        tag        = var.images["postgres"].tag_digest
        pullPolicy = "IfNotPresent"
      }
    }
    busybox = { image = { repository = var.images["busybox"].repository, tag = var.images["busybox"].tag_digest } }

    dagsterWebserver = {
      replicaCount           = var.webserver_replicas
      image                  = local.system_image
      podSecurityContext     = local.pod_secctx
      securityContext        = local.container_sctx
      initContainerResources = { requests = { cpu = "5m", memory = "16Mi" }, limits = { memory = "64Mi" } }
      resources              = var.resources["webserver"]
      volumes                = local.volumes
      volumeMounts           = local.volume_mounts
      env                    = [{ name = "HOME", value = "/tmp" }]
      logFormat              = "json"
    }

    dagsterDaemon = {
      image                  = local.system_image
      podSecurityContext     = local.pod_secctx
      securityContext        = local.container_sctx
      initContainerResources = { requests = { cpu = "5m", memory = "16Mi" }, limits = { memory = "64Mi" } }
      resources              = var.resources["daemon"]
      volumes                = local.volumes
      volumeMounts           = local.volume_mounts
      env                    = [{ name = "HOME", value = "/tmp" }]
      logFormat              = "json"
      runCoordinator = {
        enabled = true
        type    = "QueuedRunCoordinator"
      }
    }

    # the code location is a separate release (below); the system chart only
    # renders the workspace from this list (enableSubchart = false also drops
    # the busybox nslookup init containers, which fail with busybox >= 1.30)
    "dagster-user-deployments" = {
      enabled        = true
      enableSubchart = false
      deployments    = [local.code_location]
    }

    runLauncher = {
      type = "K8sRunLauncher"
      config = {
        k8sRunLauncher = {
          imagePullPolicy     = "IfNotPresent"
          resources           = var.resources["run"]
          securityContext     = local.container_sctx
          failPodOnRunFailure = true
          runK8sConfig = {
            podSpecConfig           = { securityContext = local.pod_secctx, enableServiceLinks = false }
            jobSpecConfig           = { ttlSecondsAfterFinished = var.run_ttl_seconds, backoffLimit = 0 }
            podTemplateSpecMetadata = { labels = { "app.kubernetes.io/name" = "dagster-run" } }
          }
        }
      }
    }

    # compute logs: run pods log to stdout (collected by the cluster log
    # pipeline); see docs/data-plane.md for why not S3
    computeLogManager = { type = "NoOpComputeLogManager" }

    concurrency = {
      enabled = true
      pools   = { granularity = "op" }
      runs    = { maxConcurrentRuns = var.max_concurrent_runs, tagConcurrencyLimits = [] }
    }
  })]

  depends_on = [kubernetes_manifest.solution_env]
}

# code location (gRPC server with the solution image); run pods inherit its
# image, environment, secrets and volumes through the container context
resource "helm_release" "code_location" {
  name       = "${local.name}-code"
  namespace  = var.namespace
  repository = var.charts["user_deployments"].repository
  chart      = var.charts["user_deployments"].name
  version    = var.charts["user_deployments"].version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    global = {
      postgresqlSecretName = module.db_credentials.secret_name
      dagsterHome          = "/opt/dagster/dagster_home"
    }
    deployments = [local.code_location]
  })]

  depends_on = [kubernetes_manifest.solution_env]
}

# --- pool limits (instance setting, idempotent) ------------------------------------------
resource "kubernetes_job_v1" "pools" {
  metadata {
    name      = "${local.name}-pools-${local.pools_hash}"
    namespace = var.namespace
    labels    = var.labels
  }
  spec {
    backoff_limit = 6
    template {
      metadata {
        labels = merge(var.labels, { "app.kubernetes.io/name" = "dagster-pools" })
      }
      spec {
        restart_policy                  = "OnFailure"
        automount_service_account_token = false
        enable_service_links            = false
        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "pools"
          image = var.code_location_image
          command = ["sh", "-c", join(" && ", concat(
            [for pool, limit in var.pools : "dagster instance concurrency set ${pool} ${limit}"],
            [for pool, _ in var.pools : "dagster instance concurrency get ${pool}"],
          ))]
          env {
            name  = "DAGSTER_HOME"
            value = "/opt/dagster/dagster_home"
          }
          env {
            name = "DAGSTER_PG_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.db_credentials.secret_name
                key  = "postgresql-password"
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
            requests = { cpu = "20m", memory = "128Mi" }
            limits   = { memory = "384Mi" }
          }
          volume_mount {
            name       = "instance"
            mount_path = "/opt/dagster/dagster_home"
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
          name = "instance"
          config_map {
            name = "${local.name}-instance"
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
    create = "5m"
    update = "5m"
  }
  depends_on = [helm_release.this, helm_release.code_location]
}

resource "kubernetes_pod_disruption_budget_v1" "webserver" {
  count = var.webserver_replicas > 1 ? 1 : 0
  metadata {
    name      = "${local.name}-webserver"
    namespace = var.namespace
    labels    = var.labels
  }
  spec {
    min_available = 1
    selector {
      match_labels = { component = "dagster-webserver" }
    }
  }
  depends_on = [helm_release.this]
}
