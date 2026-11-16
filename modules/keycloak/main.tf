locals {
  name            = "keycloak"
  tls_name        = "${local.name}-server-tls"
  internal_host   = "${local.name}.${var.namespace}.svc"
  internal_url    = "https://${local.internal_host}:8443"
  issuer          = "https://${var.hostname}/realms/${var.realm}"
  selector_labels = { "app.kubernetes.io/name" = local.name, "app.kubernetes.io/component" = "server" }
  labels          = merge(var.labels, local.selector_labels)
}

# --- credentials (generated in-cluster, stored in OpenBao) ---------------------------
module "admin_credentials" {
  source    = "../generated-secret"
  name      = "${local.name}-admin"
  namespace = var.namespace
  kv_path   = "${var.namespace}/keycloak-admin"
  keys      = ["password"]
  literals  = { username = "bootstrap-admin" }
  labels    = var.labels
}

module "client_credentials" {
  for_each  = var.oidc_clients
  source    = "../generated-secret"
  name      = "oidc-client-${each.key}"
  namespace = var.namespace
  kv_path   = "${var.namespace}/oidc-clients/${each.key}"
  keys      = ["client-secret"]
  literals = {
    "client-id" = each.key
    "issuer"    = local.issuer
  }
  length = 48
  labels = var.labels
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
      commonName  = local.internal_host
      duration    = "2160h0m0s"
      renewBefore = "720h0m0s"
      privateKey  = { algorithm = "RSA", size = 2048, rotationPolicy = "Always" }
      usages      = ["server auth"]
      dnsNames = [
        local.internal_host,
        "${local.internal_host}.cluster.local",
        var.hostname,
      ]
      issuerRef = { group = "cert-manager.io", kind = "ClusterIssuer", name = var.cluster_issuer }
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

# --- Keycloak ----------------------------------------------------------------------
resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }
  automount_service_account_token = false
}

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    selector = local.selector_labels
    port {
      name        = "https"
      port        = 8443
      target_port = "https"
    }
    port {
      name        = "management"
      port        = 9000
      target_port = "management"
    }
  }
  lifecycle {
    # Traefik backend-TLS annotations are owned by modules/ingress-host
    ignore_changes = [metadata[0].annotations]
  }
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    replicas = var.replicas
    selector {
      match_labels = local.selector_labels
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = var.replicas > 1 ? "0" : "1"
        max_unavailable = var.replicas > 1 ? "1" : "0"
      }
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        service_account_name             = kubernetes_service_account_v1.this.metadata[0].name
        automount_service_account_token  = false
        enable_service_links             = false
        termination_grace_period_seconds = 60
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        dynamic "topology_spread_constraint" {
          for_each = var.replicas > 1 ? [1] : []
          content {
            max_skew           = 1
            topology_key       = "kubernetes.io/hostname"
            when_unsatisfiable = "DoNotSchedule"
            label_selector {
              match_labels = local.selector_labels
            }
          }
        }
        container {
          name  = "keycloak"
          image = var.image
          args  = ["start"]

          dynamic "env" {
            for_each = {
              KC_HOSTNAME                     = "https://${var.hostname}"
              KC_HOSTNAME_BACKCHANNEL_DYNAMIC = "false"
              KC_HTTP_ENABLED                 = "false"
              KC_HTTPS_PORT                   = "8443"
              KC_HTTPS_CERTIFICATE_FILE       = "/etc/keycloak/tls/tls.crt"
              KC_HTTPS_CERTIFICATE_KEY_FILE   = "/etc/keycloak/tls/tls.key"
              KC_PROXY_HEADERS                = "xforwarded"
              KC_HEALTH_ENABLED               = "true"
              KC_METRICS_ENABLED              = "true"
              KC_DB                           = "postgres"
              KC_DB_URL_HOST                  = var.database.host
              KC_DB_URL_PORT                  = tostring(var.database.port)
              KC_DB_URL_DATABASE              = var.database.name
              KC_DB_URL_PROPERTIES            = "?sslmode=verify-full&sslrootcert=/etc/platform-ca/ca.crt"
              KC_TRUSTSTORE_PATHS             = "/etc/platform-ca/ca.crt"
              KC_CACHE                        = var.replicas > 1 ? "ispn" : "local"
              KC_LOG_CONSOLE_OUTPUT           = "json"
              KC_LOG_LEVEL                    = "INFO"
              JAVA_OPTS_KC_HEAP               = "-XX:MaxRAMPercentage=60 -XX:InitialRAMPercentage=30"
            }
            content {
              name  = env.key
              value = env.value
            }
          }
          env {
            name = "KC_DB_USERNAME"
            value_from {
              secret_key_ref {
                name = var.database.secret
                key  = "username"
              }
            }
          }
          env {
            name = "KC_DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = var.database.secret
                key  = "password"
              }
            }
          }
          env {
            name = "KC_BOOTSTRAP_ADMIN_USERNAME"
            value_from {
              secret_key_ref {
                name = module.admin_credentials.secret_name
                key  = "username"
              }
            }
          }
          env {
            name = "KC_BOOTSTRAP_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.admin_credentials.secret_name
                key  = "password"
              }
            }
          }

          port {
            name           = "https"
            container_port = 8443
          }
          port {
            name           = "management"
            container_port = 9000
          }
          port {
            name           = "jgroups"
            container_port = 7800
          }

          startup_probe {
            http_get {
              path   = "/health/started"
              port   = "management"
              scheme = "HTTPS"
            }
            period_seconds    = 5
            failure_threshold = 120
          }
          readiness_probe {
            http_get {
              path   = "/health/ready"
              port   = "management"
              scheme = "HTTPS"
            }
            period_seconds    = 10
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path   = "/health/live"
              port   = "management"
              scheme = "HTTPS"
            }
            period_seconds    = 20
            failure_threshold = 3
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }
          security_context {
            allow_privilege_escalation = false
            # Quarkus re-augments the server at start (`start` without a
            # pre-built optimised image) and writes below /opt/keycloak.
            read_only_root_filesystem = false
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "tls"
            mount_path = "/etc/keycloak/tls"
            read_only  = true
          }
          volume_mount {
            name       = "ca"
            mount_path = "/etc/platform-ca"
            read_only  = true
          }
        }
        volume {
          name = "tls"
          secret {
            secret_name = local.tls_name
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
  timeouts {
    create = "15m"
    update = "15m"
  }
  depends_on = [kubernetes_manifest.server_cert]
}

resource "kubernetes_pod_disruption_budget_v1" "this" {
  count = var.replicas > 1 ? 1 : 0
  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    max_unavailable = "1"
    selector {
      match_labels = local.selector_labels
    }
  }
}

# --- realm configuration (idempotent Job with kcadm, re-run when it changes) ---------
locals {
  realm_json = jsonencode({
    realm                  = var.realm
    enabled                = true
    displayName            = "Boccob Lakehouse"
    sslRequired            = "all"
    registrationAllowed    = false
    resetPasswordAllowed   = false
    rememberMe             = false
    loginWithEmailAllowed  = false
    duplicateEmailsAllowed = false
    bruteForceProtected    = true
    failureFactor          = 5
    passwordPolicy         = "length(14) and notUsername(undefined) and passwordHistory(5)"
    accessTokenLifespan    = 300
    ssoSessionIdleTimeout  = 1800
    ssoSessionMaxLifespan  = 36000
    # audit trail: login and admin events (also emitted to the container log)
    eventsEnabled             = true
    eventsExpiration          = 7776000
    eventsListeners           = ["jboss-logging"]
    adminEventsEnabled        = true
    adminEventsDetailsEnabled = true
  })

  roles_groups_json = jsonencode({
    ifResourceExists = "SKIP"
    roles = {
      realm = [for name, description in var.realm_roles : { name = name, description = description }]
    }
    groups = [for name, _ in var.realm_roles : { name = name, path = "/${name}", realmRoles = [name] }]
  })

  clients_json = jsonencode({
    ifResourceExists = "OVERWRITE"
    clients = [
      for id, c in var.oidc_clients : {
        clientId                  = id
        name                      = coalesce(c.name, id)
        enabled                   = true
        protocol                  = "openid-connect"
        publicClient              = false
        clientAuthenticatorType   = "client-secret"
        secret                    = "__SECRET_${upper(replace(id, "-", "_"))}__"
        standardFlowEnabled       = c.standard_flow
        implicitFlowEnabled       = false
        directAccessGrantsEnabled = c.direct_access_grants
        serviceAccountsEnabled    = c.service_account
        redirectUris              = c.redirect_uris
        webOrigins                = c.web_origins
        fullScopeAllowed          = true
        attributes = merge(
          { "post.logout.redirect.uris" = "+" },
          c.pkce_required ? { "pkce.code.challenge.method" = "S256" } : {},
        )
        protocolMappers = [
          {
            name           = "groups"
            protocol       = "openid-connect"
            protocolMapper = "oidc-group-membership-mapper"
            config = {
              "claim.name"           = "groups"
              "full.path"            = "false"
              "id.token.claim"       = "true"
              "access.token.claim"   = "true"
              "userinfo.token.claim" = "true"
            }
          },
          {
            name           = "audience"
            protocol       = "openid-connect"
            protocolMapper = "oidc-audience-mapper"
            config = {
              "included.client.audience" = id
              "id.token.claim"           = "false"
              "access.token.claim"       = "true"
            }
          },
        ]
      }
    ]
  })

  config_script = <<-SH
    set -euo pipefail
    export HOME=/tmp
    KCADM=/opt/keycloak/bin/kcadm.sh

    # kcadm needs a Java truststore: import every certificate of the platform bundle
    n=0; cert=""
    while IFS= read -r line; do
      cert+="$line"$'\n'
      if [[ "$line" == *"END CERTIFICATE"* ]]; then
        printf '%s' "$cert" > "/tmp/ca-$n.pem"
        keytool -importcert -noprompt -alias "platform-ca-$n" -file "/tmp/ca-$n.pem" \
          -keystore /tmp/truststore.p12 -storetype PKCS12 -storepass changeit >/dev/null 2>&1
        n=$((n + 1)); cert=""
      fi
    done < /etc/platform-ca/ca.crt
    "$KCADM" config truststore --trustpass changeit /tmp/truststore.p12

    tries=0
    until "$KCADM" config credentials --server "${local.internal_url}" --realm master \
            --user "$KC_ADMIN_USERNAME" --password "$KC_ADMIN_PASSWORD" >/dev/null 2>/tmp/login.err; do
      tries=$((tries + 1))
      if [[ $tries -ge 60 ]]; then cat /tmp/login.err; echo "cannot log in to Keycloak"; exit 1; fi
      sleep 5
    done

    if "$KCADM" get "realms/${var.realm}" >/dev/null 2>&1; then
      "$KCADM" update "realms/${var.realm}" -f /config/realm.json
    else
      "$KCADM" create realms -f /config/realm.json
    fi
    "$KCADM" create partialImport -r "${var.realm}" -o -f /config/roles-groups.json

    clients="$(cat /config/clients.json)"
    %{for id, _ in var.oidc_clients~}
    clients="$${clients//__SECRET_${upper(replace(id, "-", "_"))}__/$${CLIENT_SECRET_${upper(replace(id, "-", "_"))}}}"
    %{endfor~}
    ( umask 077; printf '%s' "$clients" > /tmp/clients.json )
    "$KCADM" create partialImport -r "${var.realm}" -o -f /tmp/clients.json >/dev/null
    rm -f /tmp/clients.json

    %{for id, c in var.oidc_clients~}
    %{for role in c.service_account_roles~}
    "$KCADM" add-roles -r "${var.realm}" --uusername "service-account-${id}" --rolename "${role}"
    %{endfor~}
    %{endfor~}
    echo "realm ${var.realm} configured: $(echo ${join(" ", keys(var.oidc_clients))})"
  SH

  config_hash = substr(sha256(join("\n", [local.config_script, local.realm_json, local.roles_groups_json, local.clients_json, var.image])), 0, 10)
}

resource "kubernetes_config_map_v1" "realm_config" {
  metadata {
    name      = "${local.name}-realm-config"
    namespace = var.namespace
    labels    = var.labels
  }
  data = {
    "configure.sh"      = local.config_script
    "realm.json"        = local.realm_json
    "roles-groups.json" = local.roles_groups_json
    "clients.json"      = local.clients_json
  }
}

resource "kubernetes_job_v1" "realm_config" {
  metadata {
    name      = "${local.name}-realm-config-${local.config_hash}"
    namespace = var.namespace
    labels    = var.labels
  }
  spec {
    backoff_limit = 3
    template {
      metadata {
        labels = merge(var.labels, { "app.kubernetes.io/name" = "keycloak-realm-config" })
      }
      spec {
        restart_policy                  = "OnFailure"
        automount_service_account_token = false
        enable_service_links            = false
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name    = "kcadm"
          image   = var.image
          command = ["bash", "/config/configure.sh"]
          env {
            name = "KC_ADMIN_USERNAME"
            value_from {
              secret_key_ref {
                name = module.admin_credentials.secret_name
                key  = "username"
              }
            }
          }
          env {
            name = "KC_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = module.admin_credentials.secret_name
                key  = "password"
              }
            }
          }
          dynamic "env" {
            for_each = var.oidc_clients
            content {
              name = "CLIENT_SECRET_${upper(replace(env.key, "-", "_"))}"
              value_from {
                secret_key_ref {
                  name = module.client_credentials[env.key].secret_name
                  key  = "client-secret"
                }
              }
            }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { memory = "384Mi" }
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
            name = kubernetes_config_map_v1.realm_config.metadata[0].name
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
          empty_dir {
            medium = "Memory"
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "15m"
    update = "15m"
  }
  depends_on = [kubernetes_deployment_v1.this]
}
