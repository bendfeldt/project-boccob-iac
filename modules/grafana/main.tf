# Grafana with Keycloak OIDC login only (no local login form, no anonymous
# access, no basic auth), roles from Keycloak groups, provisioned data sources
# and dashboards, HTTPS with a certificate from the platform PKI.
# Grafana OSS has no per-data-source permissions: restricted data (the audit
# trail) gets its own instance with strict role mapping (stack 30, grafana-audit).

locals {
  tls_name = "${var.name}-server-tls"
  host_svc = "${var.name}.${var.namespace}.svc"
  jp_list  = { for k in ["admin_groups", "editor_groups", "viewer_groups"] : k => [for g in var.role_mapping[k] : "contains(groups[*], '${g}')"] }
  role_path = join(" || ", compact([
    length(local.jp_list.admin_groups) > 0 ? "(${join(" || ", local.jp_list.admin_groups)}) && 'Admin'" : "",
    length(local.jp_list.editor_groups) > 0 ? "(${join(" || ", local.jp_list.editor_groups)}) && 'Editor'" : "",
    length(local.jp_list.viewer_groups) > 0 ? "(${join(" || ", local.jp_list.viewer_groups)}) && 'Viewer'" : "",
    var.role_mapping.strict ? "" : "'Viewer'",
  ]))
  security_context = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    runAsNonRoot             = true
    capabilities             = { drop = ["ALL"] }
    seccompProfile           = { type = "RuntimeDefault" }
  }
}

resource "kubernetes_manifest" "server_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = local.tls_name, namespace = var.namespace, labels = var.labels }
    spec = {
      secretName  = local.tls_name
      commonName  = local.host_svc
      dnsNames    = [local.host_svc, "${local.host_svc}.cluster.local", var.hostname]
      duration    = "2160h0m0s"
      renewBefore = "720h0m0s"
      privateKey  = { algorithm = "ECDSA", size = 256, rotationPolicy = "Always" }
      usages      = ["server auth"]
      issuerRef   = { group = "cert-manager.io", kind = "ClusterIssuer", name = var.cluster_issuer }
    }
  }
}

resource "kubernetes_config_map_v1" "dashboards" {
  count = length(var.dashboards) == 0 ? 0 : 1
  metadata {
    name      = "${var.name}-dashboards"
    namespace = var.namespace
    labels    = var.labels
  }
  data = { for k, v in var.dashboards : "${k}.json" => v }
}

resource "helm_release" "this" {
  name       = var.name
  namespace  = var.namespace
  repository = var.chart.repository
  chart      = var.chart.name
  version    = var.chart.version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    image          = { registry = var.image.registry, repository = var.image.repository_path, tag = var.image.tag_digest }
    replicas       = var.replicas
    testFramework  = { enabled = false }
    initChownData  = { enabled = false }
    persistence    = { enabled = false }
    rbac           = { create = false, pspEnabled = false }
    serviceAccount = { create = true, automountServiceAccountToken = false }
    sidecar        = { dashboards = { enabled = false }, datasources = { enabled = false } }
    resources      = var.resources
    securityContext = {
      runAsNonRoot   = true, runAsUser = 472, runAsGroup = 472, fsGroup = 472
      seccompProfile = { type = "RuntimeDefault" }
    }
    containerSecurityContext = local.security_context
    readinessProbe           = { httpGet = { path = "/api/health", port = "grafana", scheme = "HTTPS" } }
    livenessProbe            = { httpGet = { path = "/api/health", port = "grafana", scheme = "HTTPS" }, initialDelaySeconds = 60, timeoutSeconds = 30, failureThreshold = 10 }
    extraSecretMounts = [
      { name = "tls", secretName = local.tls_name, mountPath = "/etc/grafana/tls", readOnly = true },
    ]
    extraConfigmapMounts = [
      { name = "platform-ca", configMap = var.ca_configmap, mountPath = "/etc/platform-ca", readOnly = true },
    ]
    extraEmptyDirMounts = [{ name = "tmp", mountPath = "/tmp" }]
    envValueFrom = {
      GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = { secretKeyRef = { name = var.oidc.client_secret, key = "client-secret" } }
    }
    assertNoLeakedSecrets = true
    "grafana.ini" = {
      server = {
        protocol  = "https"
        cert_file = "/etc/grafana/tls/tls.crt"
        cert_key  = "/etc/grafana/tls/tls.key"
        domain    = var.hostname
        root_url  = "https://${var.hostname}${var.public_port}/"
      }
      analytics = { reporting_enabled = false, check_for_updates = false, check_for_plugin_updates = false }
      security = {
        cookie_secure                  = true
        cookie_samesite                = "lax"
        disable_initial_admin_creation = true
        disable_gravatar               = true
      }
      users = { allow_sign_up = false, auto_assign_org = true, auto_assign_org_role = "Viewer" }
      auth = {
        disable_login_form   = true
        oauth_auto_login     = true
        signout_redirect_url = "${var.oidc.issuer}/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2F${var.hostname}${urlencode(var.public_port)}%2Flogin&client_id=${var.oidc.client_id}"
      }
      "auth.anonymous" = { enabled = false }
      "auth.basic"     = { enabled = false }
      "auth.generic_oauth" = {
        enabled                    = true
        name                       = "Keycloak"
        allow_sign_up              = true
        client_id                  = var.oidc.client_id
        scopes                     = "openid profile email"
        auth_url                   = "${var.oidc.issuer}/protocol/openid-connect/auth"
        token_url                  = "${var.oidc.issuer}/protocol/openid-connect/token"
        api_url                    = "${var.oidc.issuer}/protocol/openid-connect/userinfo"
        use_pkce                   = true
        use_refresh_token          = true
        tls_client_ca              = "/etc/platform-ca/ca.crt"
        groups_attribute_path      = "groups"
        role_attribute_path        = local.role_path
        role_attribute_strict      = var.role_mapping.strict
        allow_assign_grafana_admin = false
        skip_org_role_sync         = false
        login_attribute_path       = "preferred_username"
      }
      log           = { mode = "console" }
      "log.console" = { format = "json" }
    }
    datasources = { "datasources.yaml" = { apiVersion = 1, datasources = var.datasources } }
    dashboardProviders = length(var.dashboards) == 0 ? {} : {
      "dashboardproviders.yaml" = {
        apiVersion = 1
        providers = [{
          name    = "boccob", orgId = 1, folder = "Boccob", type = "file", disableDeletion = true, editable = false
          options = { path = "/var/lib/grafana/dashboards/boccob" }
        }]
      }
    }
    # dashboards from our own ConfigMap: the chart's `dashboards` value adds a
    # download init container with an upstream curl image
    dashboardsConfigMaps = length(var.dashboards) == 0 ? {} : { boccob = kubernetes_config_map_v1.dashboards[0].metadata[0].name }
  })]

  depends_on = [kubernetes_manifest.server_cert]
}
