locals {
  owner    = coalesce(var.owner, var.database)
  kv_path  = coalesce(var.kv_path, "database/${var.name}")
  tls_name = "${var.name}-server-tls"
  ha       = var.instances > 1
  host     = "${var.name}-rw.${var.namespace}.svc"
  # PostgreSQL major version of the operand image (".../postgresql:18.7-system-trixie@sha256:.." -> "18")
  pg_major = regex("postgresql:([0-9]+)", var.image)[0]

  spec = merge(
    {
      description           = "Managed by OpenTofu (modules/postgres-cluster)"
      imageName             = var.image
      instances             = var.instances
      primaryUpdateStrategy = "unsupervised"
      enablePDB             = local.ha
      storage = merge(
        { size = var.storage_size },
        var.storage_class == null ? {} : { storageClass = var.storage_class },
      )
      resources = var.resources
      bootstrap = {
        initdb = {
          database      = var.database
          owner         = local.owner
          dataChecksums = true
          encoding      = "UTF8"
        }
      }
      postgresql = merge(
        {
          parameters = merge({
            "password_encryption"        = "scram-sha-256"
            "ssl_min_protocol_version"   = "TLSv1.2"
            "log_connections"            = "on"
            "log_disconnections"         = "on"
            "log_statement"              = "ddl"
            "log_min_duration_statement" = "2000"
          }, var.parameters)
          # TLS only, password (SCRAM) authentication for applications
          pg_hba = [
            "hostssl all all all scram-sha-256",
            "hostnossl all all all reject",
          ]
        },
        var.synchronous_replicas > 0 ? {
          synchronous = { method = "any", number = var.synchronous_replicas }
        } : {},
      )
      # server certificate from the platform PKI; clients verify it with the
      # platform-ca bundle (sslmode=verify-full, host <name>-rw.<ns>.svc)
      certificates = {
        serverTLSSecret = local.tls_name
        serverCASecret  = local.tls_name
      }
      affinity = {
        enablePodAntiAffinity = true
        topologyKey           = "kubernetes.io/hostname"
        podAntiAffinityType   = local.ha ? "required" : "preferred"
      }
      monitoring            = { enablePodMonitor = var.pod_monitor }
      inheritedMetadata     = { labels = var.labels }
      enableSuperuserAccess = false
    },
    var.wal_storage_size == null ? {} : {
      walStorage = merge(
        { size = var.wal_storage_size },
        var.storage_class == null ? {} : { storageClass = var.storage_class },
      )
    },
    var.backup == null ? {} : {
      backup = {
        retentionPolicy = var.backup.retention_policy
        # CloudNativePG's default, set explicitly: the admission webhook fills it
        # in, which the kubernetes provider reports as an inconsistent result
        # when backup is added to an existing cluster
        target = "prefer-standby"
        barmanObjectStore = {
          # barman writes below <destinationPath>/<serverName>/, one archive per
          # PostgreSQL major version: a major upgrade (pg_upgrade) starts a new system
          # with timeline 1, and pre-upgrade backups cannot be replayed into it
          # (CloudNativePG "Backup and WAL Archive Considerations")
          destinationPath = var.backup.destination_path
          serverName      = "${var.name}-pg${local.pg_major}"
          endpointURL     = var.backup.endpoint_url
          endpointCA      = { name = var.backup.ca_secret, key = "ca.crt" }
          s3Credentials = {
            accessKeyId     = { name = var.backup.credentials_secret, key = var.backup.access_key_id_key }
            secretAccessKey = { name = var.backup.credentials_secret, key = var.backup.secret_key_key }
          }
          wal = merge({ compression = "gzip" }, var.backup.encryption == null ? {} : { encryption = var.backup.encryption })
          data = merge({ compression = "gzip", immediateCheckpoint = true },
          var.backup.encryption == null ? {} : { encryption = var.backup.encryption })
        }
      }
    },
    var.extra_spec,
  )
}

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
      commonName  = local.host
      duration    = "2160h0m0s"
      renewBefore = "720h0m0s"
      privateKey  = { algorithm = "ECDSA", size = 256, rotationPolicy = "Always" }
      usages      = ["server auth"]
      dnsNames = flatten([
        for suffix in ["rw", "ro", "r"] : [
          "${var.name}-${suffix}.${var.namespace}.svc",
          "${var.name}-${suffix}.${var.namespace}.svc.cluster.local",
        ]
      ])
      issuerRef = { group = "cert-manager.io", kind = "ClusterIssuer", name = var.cluster_issuer }
      secretTemplate = {
        # CloudNativePG reloads certificates from secrets carrying this label
        labels = { "cnpg.io/reload" = "" }
      }
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

resource "kubernetes_manifest" "cluster" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = var.labels
    }
    spec = local.spec
  }
  computed_fields = ["metadata.annotations", "metadata.labels", "spec.postgresql.parameters", "spec.bootstrap.initdb"]
  wait {
    fields = {
      "status.readyInstances" = tostring(var.instances)
    }
  }
  timeouts {
    create = "15m"
    update = "15m"
  }
  depends_on = [kubernetes_manifest.server_cert]
}

resource "kubernetes_manifest" "scheduled_backup" {
  count = var.backup == null ? 0 : 1
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata = {
      name      = "${var.name}-daily"
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      schedule             = var.backup.schedule
      immediate            = var.backup.immediate
      backupOwnerReference = "self"
      cluster              = { name = var.name }
    }
  }
  depends_on = [kubernetes_manifest.cluster]
}

# Application credentials are generated by CloudNativePG (Secret <name>-app).
# Publish them in OpenBao so workloads in other namespaces can sync them.
resource "kubernetes_manifest" "push_app_credentials" {
  count = var.push_credentials ? 1 : 0
  manifest = {
    apiVersion = "external-secrets.io/v1alpha1"
    kind       = "PushSecret"
    metadata = {
      name      = "${var.name}-app"
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      refreshInterval = "1h0m0s"
      updatePolicy    = "Replace"
      deletionPolicy  = "None"
      secretStoreRefs = [
        { name = var.push_store, kind = var.store_kind },
      ]
      selector = { secret = { name = "${var.name}-app" } }
      data = [
        for key in ["username", "password", "dbname", "port"] : {
          match = {
            secretKey = key
            remoteRef = { remoteKey = local.kv_path, property = key }
          }
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
  }
  depends_on = [kubernetes_manifest.cluster]
}
