# Apache Polaris (Iceberg REST catalog) on a PostgreSQL metastore.
#
#   generated root credentials -> OpenBao -> bootstrap Job (polaris-admin-tool)
#   helm release (TLS, relational-jdbc, static S3 credentials)
#   provisioning Job: catalogs, principals, roles, grants -> principal credentials into OpenBao
#
# No secret value passes through OpenTofu.

locals {
  name                 = "polaris"
  host                 = "${local.name}.${var.namespace}.svc"
  labels               = merge(var.labels, { "app.kubernetes.io/name" = local.name })
  principals_kv_prefix = "${var.kv_prefix}/principals"
  provisioner          = "${local.name}-provisioner"
  auth_type            = var.oidc == null ? "internal" : "mixed"

  jdbc_url = join("", [
    "jdbc:postgresql://${var.database.host}:${var.database.port}/{{ .dbname }}",
    "?sslmode=verify-full&sslrootcert=/etc/platform-ca/ca.crt",
  ])

  desired = jsonencode({
    catalogs = {
      for name, c in var.catalogs : name => {
        base_location     = c.base_location
        allowed_locations = c.allowed_locations
        properties        = c.properties
        endpoint          = var.s3.endpoint
        region            = var.s3.region
      }
    }
    principals = var.principals
  })
  provision_script = file("${path.module}/files/provision.py")
  provision_hash   = substr(sha256(join("\n", [local.provision_script, local.desired, var.images["python"].ref])), 0, 10)
  bootstrap_hash   = substr(sha256(join("\n", [var.realm, var.database.host, var.database.schema, var.images["admin_tool"].ref])), 0, 10)

  ca_volume         = { name = "platform-ca", configMap = { name = var.ca_configmap } }
  ca_volume_mount   = { name = "platform-ca", mountPath = "/etc/platform-ca", readOnly = true }
  container_secctx  = { allowPrivilegeEscalation = false, runAsNonRoot = true, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] }, seccompProfile = { type = "RuntimeDefault" } }
  topology_spread   = var.replicas > 1 ? [{ maxSkew = 1, topologyKey = "kubernetes.io/hostname", whenUnsatisfiable = "ScheduleAnyway" }] : []
  oidc_secret_name  = "${local.name}-oidc"
  db_secret_name    = "${local.name}-db"
  s3_secret_name    = "${local.name}-s3"
  boot_secret_name  = "${local.name}-bootstrap"
  root_secret_name  = "${local.name}-root"
  token_secret_name = "${local.name}-token-broker"
}

# --- secrets -------------------------------------------------------------------
module "root_credentials" {
  source    = "../generated-secret"
  name      = local.root_secret_name
  namespace = var.namespace
  kv_path   = "${var.kv_prefix}/root"
  keys      = ["client-secret"]
  literals  = { "client-id" = "root", realm = var.realm }
  labels    = var.labels
}

# credentials file for `polaris-admin-tool bootstrap -f` (keeps the secret off argv)
module "bootstrap_credentials" {
  source    = "../external-secret"
  name      = local.boot_secret_name
  namespace = var.namespace
  kv_path   = module.root_credentials.kv_path
  template = {
    "credentials.yaml" = "{{ .realm }}:\n  client-id: {{ index . \"client-id\" }}\n  client-secret: {{ index . \"client-secret\" }}\n"
  }
  labels = var.labels
}

# signing key of Polaris' own token endpoint; shared by all replicas
module "token_broker_key" {
  source    = "../generated-secret"
  name      = local.token_secret_name
  namespace = var.namespace
  kv_path   = "${var.kv_prefix}/token-broker"
  keys      = ["symmetric.key"]
  length    = 64
  labels    = var.labels
}

module "db_credentials" {
  source    = "../external-secret"
  name      = local.db_secret_name
  namespace = var.namespace
  kv_path   = var.database.kv_path
  template = {
    username = "{{ .username }}"
    password = "{{ .password }}"
    dbname   = "{{ .dbname }}"
    jdbcUrl  = local.jdbc_url
  }
  labels = var.labels
}

module "s3_credentials" {
  source    = "../external-secret"
  name      = local.s3_secret_name
  namespace = var.namespace
  kv_path   = var.s3.credentials_kv_path
  labels    = var.labels
}

module "oidc_credentials" {
  count     = var.oidc == null ? 0 : 1
  source    = "../external-secret"
  name      = local.oidc_secret_name
  namespace = var.namespace
  kv_path   = var.oidc.client_secret_kv_path
  template  = { clientSecret = "{{ index . \"client-secret\" }}" }
  labels    = var.labels
}

# --- TLS -------------------------------------------------------------------------
module "tls" {
  source         = "../tls-certificate"
  name           = "${local.name}-tls"
  namespace      = var.namespace
  dns_names      = [local.host, "${local.host}.cluster.local"]
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

# --- realm bootstrap (idempotent: a bootstrapped realm is left untouched) -----
resource "kubernetes_job_v1" "bootstrap" {
  metadata {
    name      = "${local.name}-bootstrap-${local.bootstrap_hash}"
    namespace = var.namespace
    labels    = var.labels
  }
  spec {
    backoff_limit = 6
    template {
      metadata {
        labels = merge(var.labels, { "app.kubernetes.io/name" = "polaris-bootstrap" })
      }
      spec {
        restart_policy                  = "OnFailure"
        automount_service_account_token = false
        enable_service_links            = false
        security_context {
          run_as_non_root = true
          run_as_user     = 10000
          run_as_group    = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        # Polaris does not create its schema (since 1.9): the database owner does
        init_container {
          name    = "schema"
          image   = var.images["postgres"].ref
          command = ["psql", "-v", "ON_ERROR_STOP=1", "-c", "CREATE SCHEMA IF NOT EXISTS ${var.database.schema}"]
          env {
            name  = "PGHOST"
            value = var.database.host
          }
          env {
            name  = "PGPORT"
            value = tostring(var.database.port)
          }
          env {
            name  = "PGSSLMODE"
            value = "verify-full"
          }
          env {
            name  = "PGSSLROOTCERT"
            value = "/etc/platform-ca/ca.crt"
          }
          env {
            name = "PGUSER"
            value_from {
              secret_key_ref {
                name = module.db_credentials.secret_name
                key  = "username"
              }
            }
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = module.db_credentials.secret_name
                key  = "password"
              }
            }
          }
          env {
            name = "PGDATABASE"
            value_from {
              secret_key_ref {
                name = module.db_credentials.secret_name
                key  = "dbname"
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
            name       = "ca"
            mount_path = "/etc/platform-ca"
            read_only  = true
          }
        }
        container {
          name  = "bootstrap"
          image = var.images["admin_tool"].ref
          args  = ["bootstrap", "-f", "/bootstrap/credentials.yaml"]
          env {
            name  = "polaris.persistence.type"
            value = "relational-jdbc"
          }
          env {
            name  = "quarkus.datasource.jdbc.additional-jdbc-properties.currentSchema"
            value = var.database.schema
          }
          env {
            name = "quarkus.datasource.username"
            value_from {
              secret_key_ref {
                name = module.db_credentials.secret_name
                key  = "username"
              }
            }
          }
          env {
            name = "quarkus.datasource.password"
            value_from {
              secret_key_ref {
                name = module.db_credentials.secret_name
                key  = "password"
              }
            }
          }
          env {
            name = "quarkus.datasource.jdbc.url"
            value_from {
              secret_key_ref {
                name = module.db_credentials.secret_name
                key  = "jdbcUrl"
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
            requests = { cpu = "20m", memory = "192Mi" }
            limits   = { memory = "512Mi" }
          }
          volume_mount {
            name       = "ca"
            mount_path = "/etc/platform-ca"
            read_only  = true
          }
          volume_mount {
            name       = "bootstrap"
            mount_path = "/bootstrap"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }
        volume {
          name = "ca"
          config_map {
            name = var.ca_configmap
          }
        }
        volume {
          name = "bootstrap"
          secret {
            secret_name = module.bootstrap_credentials.secret_name
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
}

# --- Polaris ----------------------------------------------------------------------
resource "helm_release" "this" {
  name       = local.name
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    fullnameOverride = local.name
    replicaCount     = var.replicas
    image            = { repository = var.images["polaris"].repository, tag = var.images["polaris"].tag_digest }
    podLabels        = var.labels
    podAnnotations = {
      "boccob.io/ca-checksum" = module.truststore.checksum
    }
    podDisruptionBudget       = { enabled = var.replicas > 1, minAvailable = var.replicas > 1 ? 1 : 0, maxUnavailable = 0 }
    topologySpreadConstraints = local.topology_spread
    containerSecurityContext  = merge(local.container_secctx, { runAsUser = 10000 })
    resources                 = var.resources

    service = {
      ports = [{ name = "polaris-https", port = 8181, targetPort = 8181, protocol = "TCP" }]
    }
    extraServices  = []
    serviceMonitor = { enabled = var.service_monitor }

    realmContext = { type = "default", realms = [var.realm] }
    features = merge({
      SUPPORTED_CATALOG_STORAGE_TYPES = ["S3"]
      DROP_WITH_PURGE_ENABLED         = true
    }, var.features)

    persistence = {
      type = "relational-jdbc"
      relationalJdbc = {
        additionalProperties = { currentSchema = var.database.schema }
        secret               = { name = module.db_credentials.secret_name, username = "username", password = "password", jdbcUrl = "jdbcUrl" }
      }
    }
    # static credentials: RustFS has no STS, catalogs are created with stsUnavailable
    storage = {
      secret = { name = module.s3_credentials.secret_name, awsAccessKeyId = "access-key", awsSecretAccessKey = "secret-key" }
    }
    authentication = {
      type = local.auth_type
      tokenBroker = {
        type               = "symmetric-key"
        maxTokenGeneration = "PT1H"
        secret             = { name = module.token_broker_key.secret_name, symmetricKey = { secretKey = "symmetric.key" } }
      }
    }
    logging = { console = { enabled = true, json = var.json_logs } }

    advancedConfig = { for k, v in {
      # TLS only on the API port; the management port (health, metrics) stays
      # plain HTTP for kubelet probes and is closed by NetworkPolicy
      "quarkus.http.insecure-requests"             = "disabled"
      "quarkus.http.ssl-port"                      = "8181"
      "quarkus.http.port"                          = "8180"
      "quarkus.http.ssl.certificate.files"         = "/tls/tls.crt"
      "quarkus.http.ssl.certificate.key-files"     = "/tls/tls.key"
      "quarkus.http.ssl.certificate.reload-period" = "1h"
      "quarkus.http.access-log.enabled"            = "true"
      "quarkus.oidc.tls.trust-store-file"          = var.oidc == null ? null : module.truststore.path
      "quarkus.oidc.tls.trust-store-password"      = var.oidc == null ? null : "changeit"
    } : k => v if v != null }

    extraEnv = [
      { name = "JAVA_OPTS_APPEND", value = join(" ", module.truststore.jvm_flags) },
      { name = "AWS_REGION", value = var.s3.region },
    ]
    extraInitContainers = [{
      name            = "truststore"
      image           = var.images["polaris"].ref
      command         = module.truststore.command
      securityContext = merge(local.container_secctx, { runAsUser = 10000 })
      resources       = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
      volumeMounts = [
        { name = "truststore-src", mountPath = "/truststore-src", readOnly = true },
        { name = "truststore", mountPath = "/truststore" },
      ]
    }]
    extraVolumes = [
      local.ca_volume,
      { name = "tls", secret = { secretName = module.tls.secret_name } },
      { name = "truststore-src", configMap = { name = module.truststore.configmap } },
      { name = "truststore", emptyDir = {} },
    ]
    extraVolumeMounts = [
      local.ca_volume_mount,
      { name = "tls", mountPath = "/tls", readOnly = true },
      { name = "truststore", mountPath = "/truststore", readOnly = true },
    ]
    }), yamlencode({ for k, v in {
      oidc = {
        authServeUrl         = try(var.oidc.issuer, "")
        client               = { id = try(var.oidc.client_id, ""), secret = { name = local.oidc_secret_name, key = "clientSecret" } }
        principalMapper      = { type = "default", nameClaimPath = try(var.oidc.principal_name_claim, "") }
        principalRolesMapper = { type = "default", rolesClaimPath = try(var.oidc.roles_claim, "") }
      }
  } : k => v if var.oidc != null })]

  depends_on = [kubernetes_job_v1.bootstrap, module.oidc_credentials]
}

# --- provisioning: catalogs, principals, grants ---------------------------------
resource "kubernetes_service_account_v1" "provisioner" {
  metadata {
    name      = local.provisioner
    namespace = var.namespace
    labels    = var.labels
  }
  automount_service_account_token = false
}

resource "vault_policy" "provisioner" {
  name   = "${var.namespace}-${local.provisioner}"
  policy = <<-HCL
    path "${var.openbao.kv_mount}/data/${local.principals_kv_prefix}/*" {
      capabilities = ["create", "read", "update"]
    }
  HCL
}

resource "vault_kubernetes_auth_backend_role" "provisioner" {
  backend                          = var.openbao.auth_backend
  role_name                        = "${var.namespace}-${local.provisioner}"
  bound_service_account_names      = [kubernetes_service_account_v1.provisioner.metadata[0].name]
  bound_service_account_namespaces = [var.namespace]
  token_policies                   = [vault_policy.provisioner.name]
  token_ttl                        = 600
  token_max_ttl                    = 900
}

resource "kubernetes_config_map_v1" "provision" {
  metadata {
    name      = "${local.name}-provision"
    namespace = var.namespace
    labels    = var.labels
  }
  data = {
    "provision.py" = local.provision_script
    "desired.json" = local.desired
  }
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
        labels = merge(var.labels, { "app.kubernetes.io/name" = "polaris-provision" })
      }
      spec {
        restart_policy                  = "OnFailure"
        service_account_name            = kubernetes_service_account_v1.provisioner.metadata[0].name
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
          name    = "provision"
          image   = var.images["python"].ref
          command = ["python", "-I", "/config/provision.py"]
          env {
            name  = "POLARIS_URL"
            value = "https://${local.host}:8181"
          }
          env {
            name  = "POLARIS_REALM"
            value = var.realm
          }
          env {
            name  = "OPENBAO_URL"
            value = var.openbao.url
          }
          env {
            name  = "OPENBAO_ROLE"
            value = vault_kubernetes_auth_backend_role.provisioner.role_name
          }
          env {
            name  = "OPENBAO_KV_MOUNT"
            value = var.openbao.kv_mount
          }
          env {
            name  = "KV_PREFIX"
            value = local.principals_kv_prefix
          }
          env {
            name = "POLARIS_ROOT_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = module.root_credentials.secret_name
                key  = "client-id"
              }
            }
          }
          env {
            name = "POLARIS_ROOT_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = module.root_credentials.secret_name
                key  = "client-secret"
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
            requests = { cpu = "10m", memory = "48Mi" }
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
