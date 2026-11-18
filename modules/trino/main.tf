# Trino (official chart): coordinator (+ optional autoscaled workers),
# Iceberg REST catalogs on Polaris, S3 on RustFS over TLS, OAuth2 (Keycloak)
# and password authentication, Keycloak groups through a synced file group
# provider, OPA access control, query audit events on stdout.

locals {
  name = "trino"
  host = "${local.name}.${var.namespace}.svc"

  coordinator_pod_labels = { "app.kubernetes.io/name" = local.name, "app.kubernetes.io/component" = "coordinator" }
  worker_pod_labels      = { "app.kubernetes.io/name" = local.name, "app.kubernetes.io/component" = "worker" }

  sa_kv_prefix = "${var.kv_prefix}/service-accounts"
  static_groups = {
    for g in distinct(flatten([for _, sa in var.service_accounts : sa.groups])) :
    g => sort([for n, sa in var.service_accounts : n if contains(sa.groups, g)])
  }

  pod_secctx = {
    runAsUser      = 1000, runAsGroup = 1000, fsGroup = 1000, runAsNonRoot = true
    seccompProfile = { type = "RuntimeDefault" }
  }
  container_secctx = {
    allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, runAsNonRoot = true
    capabilities             = { drop = ["ALL"] }, seccompProfile = { type = "RuntimeDefault" }
  }

  catalog_properties = {
    for trino_name, warehouse in var.catalogs : trino_name => join("\n", [
      "connector.name=iceberg",
      "iceberg.catalog.type=rest",
      "iceberg.rest-catalog.uri=${var.polaris.uri}",
      "iceberg.rest-catalog.warehouse=${warehouse}",
      "iceberg.rest-catalog.security=OAUTH2",
      "iceberg.rest-catalog.oauth2.credential=$${ENV:POLARIS_CREDENTIAL}",
      "iceberg.rest-catalog.oauth2.scope=${var.polaris.scope}",
      "iceberg.rest-catalog.vended-credentials-enabled=false",
      "iceberg.file-format=PARQUET",
      "fs.native-s3.enabled=true",
      "s3.endpoint=${var.s3.endpoint}",
      "s3.path-style-access=true",
      "s3.region=${var.s3.region}",
      "s3.aws-access-key=$${ENV:S3_ACCESS_KEY_ID}",
      "s3.aws-secret-key=$${ENV:S3_SECRET_ACCESS_KEY}",
    ])
  }

  opa_properties = join("\n", [
    "access-control.name=opa",
    "opa.policy.uri=${var.opa_url}/v1/data/trino/allow",
    "opa.policy.batched-uri=${var.opa_url}/v1/data/trino/batch",
    "opa.policy.row-filters-uri=${var.opa_url}/v1/data/trino/rowFilters",
    "opa.policy.batch-column-masking-uri=${var.opa_url}/v1/data/trino/batchColumnMasks",
    "opa.allow-permission-management-operations=false",
  ])

  rg = var.resource_groups
  resource_groups_json = jsonencode({
    rootGroups = [
      { name = "admin", softMemoryLimit = "100%", hardConcurrencyLimit = local.rg.admin_concurrency, maxQueued = local.rg.max_queued },
      { name = "etl", softMemoryLimit = local.rg.etl_memory, hardConcurrencyLimit = local.rg.etl_concurrency, maxQueued = local.rg.max_queued },
      {
        name      = "interactive", softMemoryLimit = local.rg.interactive_memory, hardConcurrencyLimit = local.rg.interactive_concurrency, maxQueued = local.rg.max_queued
        subGroups = [{ name = "$${USER}", softMemoryLimit = "50%", hardConcurrencyLimit = local.rg.interactive_user_concurrency, maxQueued = 20 }]
      },
    ]
    selectors = [
      { userGroup = "platform-admin", group = "admin" },
      { user = "svc-.*", group = "etl" },
      { group = "interactive.$${USER}" },
    ]
  })

  jmx_config = yamlencode({
    hostPort            = "localhost:9080"
    startDelaySeconds   = 0
    ssl                 = false
    lowercaseOutputName = true
    includeObjectNames = [
      "java.lang:type=Memory", "java.lang:type=Threading", "java.lang:type=GarbageCollector,*",
      "trino.execution:name=QueryManager", "trino.execution:name=SqlTaskManager",
      "trino.memory:type=ClusterMemoryPool,*", "trino.memory:type=MemoryPool,*",
      "trino.failuredetector:name=HeartbeatFailureDetector",
    ]
    rules = [{ pattern = ".*" }]
  })

  truststore_volumes = [
    { name = "truststore-src", configMap = { name = module.truststore.configmap } },
    { name = "truststore", emptyDir = {} },
    { name = "data", emptyDir = {} },
    { name = "tmp", emptyDir = {} },
  ]
  truststore_mounts = [
    { name = "truststore", mountPath = "/truststore", readOnly = true },
    { name = "data", mountPath = "/data/trino" },
    { name = "tmp", mountPath = "/tmp" },
  ]
  truststore_init = {
    name            = "truststore"
    image           = var.images["trino"].ref
    command         = module.truststore.command
    securityContext = local.container_secctx
    resources       = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    volumeMounts = [
      { name = "truststore-src", mountPath = "/truststore-src", readOnly = true },
      { name = "truststore", mountPath = "/truststore" },
    ]
  }

  sidecar_common = {
    image           = var.images["python"].ref
    securityContext = merge(local.container_secctx, { runAsUser = 65532, runAsGroup = 65532 })
  }

  secret_env = [
    { name = "POLARIS_CREDENTIAL", valueFrom = { secretKeyRef = { name = module.polaris_credentials.secret_name, key = "credential" } } },
    { name = "S3_ACCESS_KEY_ID", valueFrom = { secretKeyRef = { name = module.s3_credentials.secret_name, key = "access-key" } } },
    { name = "S3_SECRET_ACCESS_KEY", valueFrom = { secretKeyRef = { name = module.s3_credentials.secret_name, key = "secret-key" } } },
    { name = "TRINO_SHARED_SECRET", valueFrom = { secretKeyRef = { name = module.shared_secret.secret_name, key = "shared-secret" } } },
    { name = "OAUTH2_CLIENT_SECRET", valueFrom = { secretKeyRef = { name = module.oidc_credentials.secret_name, key = "client-secret" } } },
  ]

  autoscaling = var.worker_autoscaling
  use_keda    = local.autoscaling.enabled && length(local.autoscaling.keda_triggers) > 0
}

# --- secrets --------------------------------------------------------------------------
module "shared_secret" {
  source     = "../generated-secret"
  read_store = var.secret_stores.read
  push_store = var.secret_stores.push
  store_kind = var.secret_stores.kind
  name       = "${local.name}-shared-secret"
  namespace  = var.namespace
  kv_path    = "${var.kv_prefix}/shared-secret"
  keys       = ["shared-secret"]
  length     = 64
  labels     = var.labels
}

module "polaris_credentials" {
  source     = "../external-secret"
  store      = var.secret_stores.read
  store_kind = var.secret_stores.kind
  name       = "${local.name}-polaris"
  namespace  = var.namespace
  kv_path    = var.polaris.credentials_kv_path
  labels     = var.labels
}

module "s3_credentials" {
  source     = "../external-secret"
  store      = var.secret_stores.read
  store_kind = var.secret_stores.kind
  name       = "${local.name}-s3"
  namespace  = var.namespace
  kv_path    = var.s3.credentials_kv_path
  labels     = var.labels
}

module "oidc_credentials" {
  source     = "../external-secret"
  store      = var.secret_stores.read
  store_kind = var.secret_stores.kind
  name       = "${local.name}-oidc"
  namespace  = var.namespace
  kv_path    = var.oidc.client_secret_kv_path
  labels     = var.labels
}

module "group_sync_credentials" {
  source     = "../external-secret"
  store      = var.secret_stores.read
  store_kind = var.secret_stores.kind
  name       = "${local.name}-group-sync"
  namespace  = var.namespace
  kv_path    = var.group_sync.client_secret_kv_path
  labels     = var.labels
}

module "service_account_passwords" {
  for_each   = var.service_accounts
  source     = "../generated-secret"
  read_store = var.secret_stores.read
  push_store = var.secret_stores.push
  store_kind = var.secret_stores.kind
  name       = "${local.name}-sa-${each.key}"
  namespace  = var.namespace
  kv_path    = "${local.sa_kv_prefix}/${each.key}"
  keys       = ["password"]
  literals   = { username = each.key }
  labels     = var.labels
}

# bcrypt password file, rendered by External Secrets from the values in OpenBao
# (Trino accepts the $2y$ prefix only; the hash is otherwise identical to $2a$)
resource "kubernetes_manifest" "password_file" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.name}-password-file"
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      refreshInterval = "1h0m0s"
      secretStoreRef  = { name = var.secret_stores.read, kind = var.secret_stores.kind }
      target = {
        name           = "${local.name}-password-file"
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            "password.db" = join("", [
              for name, _ in var.service_accounts :
              "${name}:{{ index . \"${replace(name, "-", "_")}\" | bcrypt | replace \"$2a$\" \"$2y$\" }}\n"
            ])
          }
        }
      }
      data = [
        for name, _ in var.service_accounts : {
          secretKey = replace(name, "-", "_")
          remoteRef = { key = module.service_account_passwords[name].kv_path, property = "password" }
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
}

# --- TLS ----------------------------------------------------------------------------------
module "tls" {
  source         = "../tls-certificate"
  name           = "${local.name}-tls"
  namespace      = var.namespace
  dns_names      = [local.host, "${local.host}.cluster.local"]
  combined_pem   = true
  cluster_issuer = var.cluster_issuer
  labels         = var.labels
}

module "truststore" {
  source        = "../java-truststore"
  name          = "${local.name}-truststore"
  namespace     = var.namespace
  ca_bundle_pem = var.ca_bundle_pem
  labels        = var.labels
}

resource "kubernetes_config_map_v1" "sidecars" {
  metadata {
    name      = "${local.name}-sidecars"
    namespace = var.namespace
    labels    = var.labels
  }
  data = {
    "group_sync.py" = file("${path.module}/files/group_sync.py")
    "audit_sink.py" = file("${path.module}/files/audit_sink.py")
  }
}

# --- Trino ------------------------------------------------------------------------------
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
    image = {
      registry   = ""
      repository = var.images["trino"].repository
      tag        = var.images["trino"].tag
      digest     = var.images["trino"].digest
    }
    commonLabels = var.labels

    server = {
      workers = var.workers
      node    = { environment = var.environment }
      log     = { trino = { level = "INFO" } }
      config = {
        https              = { enabled = true, port = 8443, keystore = { path = "/etc/trino-tls/tls-combined.pem" } }
        authenticationType = "OAUTH2,PASSWORD"
        query              = { maxMemory = var.coordinator.query_max_memory }
      }
      coordinatorExtraConfig = join("\n", [
        "web-ui.authentication.type=oauth2",
        "http-server.authentication.oauth2.issuer=${var.oidc.issuer}",
        "http-server.authentication.oauth2.client-id=${var.oidc.client_id}",
        "http-server.authentication.oauth2.client-secret=$${ENV:OAUTH2_CLIENT_SECRET}",
        "http-server.authentication.oauth2.principal-field=${var.oidc.principal_field}",
        "http-server.authentication.oauth2.scopes=openid",
        "http-server.authentication.oauth2.oidc.use-userinfo-endpoint=false",
        "http-server.authentication.oauth2.refresh-tokens=true",
        length(var.oidc.additional_audiences) > 0 ? "http-server.authentication.oauth2.additional-audiences=${join(",", var.oidc.additional_audiences)}" : "",
        # Traefik terminates the public TLS connection and forwards X-Forwarded-*
        "http-server.process-forwarded=true",
      ])
      autoscaling = {
        enabled                           = local.autoscaling.enabled && !local.use_keda
        maxReplicas                       = local.autoscaling.max_replicas
        targetCPUUtilizationPercentage    = local.autoscaling.target_cpu_utilization
        targetMemoryUtilizationPercentage = local.autoscaling.target_memory_utilization
        behavior = {
          scaleDown = { stabilizationWindowSeconds = local.autoscaling.scale_down_stabilization_s }
        }
      }
      keda = {
        enabled         = local.use_keda
        minReplicaCount = var.workers
        maxReplicaCount = local.autoscaling.max_replicas
        triggers        = local.autoscaling.keda_triggers
      }
    }
    additionalConfigProperties = concat([
      "internal-communication.shared-secret=$${ENV:TRINO_SHARED_SECRET}",
    ], var.extra_config_properties)

    accessControl = {
      coordinator = { type = "properties", properties = local.opa_properties }
      # workers decide nothing about data; the file rules only cover the
      # graceful-shutdown request (merged by the chart)
      worker = { type = "configmap", rules = { "rules.json" = jsonencode({ system_information = [] }) } }
    }
    resourceGroups = { type = "configmap", resourceGroupsConfig = local.resource_groups_json }

    eventListenerProperties = [
      "event-listener.name=http",
      "http-event-listener.log-created=false",
      "http-event-listener.log-completed=true",
      "http-event-listener.connect-ingest-uri=http://127.0.0.1:8090/",
      "http-event-listener.connect-retry-count=3",
    ]

    catalogs           = { tpch = null, tpcds = null }
    additionalCatalogs = local.catalog_properties

    auth = { passwordAuthSecret = kubernetes_manifest.password_file.manifest.spec.target.name }

    env = local.secret_env

    securityContext          = local.pod_secctx
    containerSecurityContext = local.container_secctx

    initContainers = {
      coordinator = [
        local.truststore_init,
        merge(local.sidecar_common, {
          name         = "group-file-init"
          command      = ["python", "-I", "/sidecars/group_sync.py", "--once-static"]
          env          = [{ name = "STATIC_GROUPS", value = jsonencode(local.static_groups) }]
          resources    = { requests = { cpu = "5m", memory = "16Mi" }, limits = { memory = "64Mi" } }
          volumeMounts = [{ name = "sidecars", mountPath = "/sidecars", readOnly = true }, { name = "groups", mountPath = "/groups" }]
        }),
      ]
      worker = [local.truststore_init]
    }
    sidecarContainers = {
      coordinator = [
        merge(local.sidecar_common, {
          name    = "group-sync"
          command = ["python", "-I", "/sidecars/group_sync.py"]
          env = [
            { name = "STATIC_GROUPS", value = jsonencode(local.static_groups) },
            { name = "KEYCLOAK_URL", value = var.group_sync.keycloak_url },
            { name = "KEYCLOAK_REALM", value = var.group_sync.realm },
            { name = "KEYCLOAK_CLIENT_ID", value = var.group_sync.client_id },
            { name = "KEYCLOAK_CLIENT_SECRET", valueFrom = { secretKeyRef = { name = module.group_sync_credentials.secret_name, key = "client-secret" } } },
            { name = "GROUP_NAMES", value = join(",", var.group_sync.group_names) },
            { name = "STATIC_ONLY_GROUPS", value = join(",", setsubtract(keys(local.static_groups), var.group_sync.group_names)) },
            { name = "SYNC_INTERVAL_SECONDS", value = tostring(var.group_sync.interval_seconds) },
          ]
          resources = { requests = { cpu = "5m", memory = "24Mi" }, limits = { memory = "96Mi" } }
          volumeMounts = [
            { name = "sidecars", mountPath = "/sidecars", readOnly = true },
            { name = "groups", mountPath = "/groups" },
            { name = "platform-ca", mountPath = "/etc/platform-ca", readOnly = true },
          ]
        }),
        merge(local.sidecar_common, {
          name         = "audit-log"
          command      = ["python", "-I", "/sidecars/audit_sink.py"]
          env          = [{ name = "AUDIT_FULL_EVENTS", value = tostring(var.audit_full_events) }]
          resources    = { requests = { cpu = "5m", memory = "24Mi" }, limits = { memory = "96Mi" } }
          volumeMounts = [{ name = "sidecars", mountPath = "/sidecars", readOnly = true }]
        }),
      ]
    }

    coordinator = {
      jvm = { maxHeapSize = var.coordinator.heap }
      config = {
        nodeScheduler = { includeCoordinator = var.workers == 0 }
        query         = { maxMemoryPerNode = var.coordinator.query_max_memory_per_node }
      }
      additionalJVMConfig = module.truststore.jvm_flags
      resources           = var.coordinator.resources
      annotations = {
        "boccob.io/ca-checksum"       = module.truststore.checksum
        "boccob.io/sidecars-checksum" = sha256(jsonencode(kubernetes_config_map_v1.sidecars.data))
      }
      additionalConfigFiles = {
        "group-provider.properties" = "group-provider.name=file\nfile.group-file=/groups/group.db\nfile.refresh-period=10s\n"
      }
      additionalVolumes = concat(local.truststore_volumes, [
        { name = "sidecars", configMap = { name = kubernetes_config_map_v1.sidecars.metadata[0].name } },
        { name = "groups", emptyDir = {} },
        { name = "platform-ca", configMap = { name = var.ca_configmap } },
      ])
      additionalVolumeMounts = concat(local.truststore_mounts, [
        { name = "groups", mountPath = "/groups", readOnly = true },
      ])
      secretMounts = [{ name = "tls", secretName = module.tls.secret_name, path = "/etc/trino-tls" }]
    }

    worker = {
      jvm                 = { maxHeapSize = var.worker.heap }
      config              = { query = { maxMemoryPerNode = var.worker.query_max_memory_per_node } }
      additionalJVMConfig = module.truststore.jvm_flags
      resources           = var.worker.resources
      annotations         = { "boccob.io/ca-checksum" = module.truststore.checksum }
      gracefulShutdown = {
        enabled            = true
        gracePeriodSeconds = var.worker.graceful_shutdown_seconds
        user               = "trino-shutdown"
      }
      terminationGracePeriodSeconds = var.worker.graceful_shutdown_seconds * 2 + 30
      podDisruptionBudget           = var.workers > 1 ? { maxUnavailable = 1 } : {}
      topologySpreadConstraints = var.workers > 1 ? [{
        maxSkew       = 1, topologyKey = "kubernetes.io/hostname", whenUnsatisfiable = "ScheduleAnyway"
        labelSelector = { matchLabels = local.worker_pod_labels }
      }] : []
      additionalVolumes      = local.truststore_volumes
      additionalVolumeMounts = local.truststore_mounts
    }

    jmx = {
      enabled = var.jmx_exporter
      exporter = {
        enabled          = var.jmx_exporter
        image            = var.images["jmx_exporter"].ref
        port             = 5556
        configProperties = local.jmx_config
        securityContext  = merge(local.container_secctx, { runAsUser = 1001 })
        resources        = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "192Mi" } }
      }
    }
    serviceMonitor = {
      enabled     = var.service_monitor
      coordinator = { enabled = var.service_monitor }
      worker      = { enabled = var.service_monitor }
    }
  })]
}
