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
  # job-scoped secrets (not in the code server, not in other runs): see var.job_secrets
  job_secret_names = { for name, _ in var.job_secrets : name => "${var.code_location_name}-${name}-env" }
  job_secret_env = { for name, secret in local.job_secret_names :
    coalesce(var.job_secrets[name].name_env, "${upper(replace(name, "-", "_"))}_ENV_SECRET") => secret
  }
  # S3 compute logs: credential Secret + region for every pod that loads the instance
  compute_logs_secret = "${local.name}-compute-logs-s3"
  compute_logs_env    = var.compute_logs == null ? {} : { AWS_DEFAULT_REGION = var.compute_logs.region }
  system_env          = concat([{ name = "HOME", value = "/tmp" }], [for k, v in local.compute_logs_env : { name = k, value = v }])
  system_env_secrets  = var.compute_logs == null ? [] : [{ name = local.compute_logs_secret }]
  env_map             = merge(local.tls_env, local.job_secret_env, local.compute_logs_env, var.solution_env)
  env_list            = [for k, v in local.env_map : { name = k, value = v }]
  # fields a run's user-defined k8s config may use (container context + purge tag env_from)
  run_config_allowlist = {
    container_config           = { env = true, env_from = true, volume_mounts = true, resources = true, image_pull_policy = true }
    pod_spec_config            = { volumes = true, service_account_name = true, automount_service_account_token = true, security_context = true }
    pod_template_spec_metadata = { annotations = true }
    namespace                  = true
  }

  code_location = {
    name               = var.code_location_name
    image              = local.code_image
    dagsterApiGrpcArgs = ["--module-name", var.code_location_module]
    port               = 4000
    env                = local.env_list
    envSecrets         = concat([{ name = local.env_secret }], local.system_env_secrets)
    # run pods inherit these: writable $DAGSTER_HOME (op outputs of the default
    # fs IO manager in storage/, history/), the root filesystem is read-only
    volumes                     = concat(local.volumes, [{ name = "dagster-home", emptyDir = {} }])
    volumeMounts                = concat(local.volume_mounts, [{ name = "dagster-home", mountPath = "/opt/dagster/dagster_home" }])
    includeConfigInLaunchedRuns = { enabled = true }
    # roll the code server when the set of secret variables changes (envFrom is read at start)
    annotations        = { "boccob.io/env-secret-keys" = substr(sha256(join(",", sort(keys(var.solution_secrets)))), 0, 16) }
    podSecurityContext = local.pod_secctx
    securityContext    = local.container_sctx
    resources          = var.resources["code_location"]
    # no labels here: they would enter the container context and the run allowlist
    # (a run tag could then forge dagster/job); run labels come from the launcher
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

# S3 user of the compute log manager, mapped to the AWS SDK variables
module "compute_logs_credentials" {
  count      = var.compute_logs == null ? 0 : 1
  source     = "../external-secret"
  store      = var.secret_stores.read
  store_kind = var.secret_stores.kind
  name       = local.compute_logs_secret
  namespace  = var.namespace
  kv_path    = var.compute_logs.kv_path
  template = {
    AWS_ACCESS_KEY_ID     = "{{ index . \"access-key\" }}"
    AWS_SECRET_ACCESS_KEY = "{{ index . \"secret-key\" }}"
  }
  labels = var.labels
}

# job-scoped secrets: one Secret per entry, attached only by the listed jobs
resource "kubernetes_manifest" "job_secret" {
  for_each = var.job_secrets
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.job_secret_names[each.key]
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      refreshInterval = "5m0s"
      secretStoreRef  = { name = var.secret_stores.read, kind = var.secret_stores.kind }
      target          = { name = local.job_secret_names[each.key], creationPolicy = "Owner", deletionPolicy = "Retain" }
      data = [for env_name, ref in each.value.env : {
        secretKey = env_name
        remoteRef = { key = ref.kv_path, property = ref.property }
      }]
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

# Admission guard (built-in ValidatingAdmissionPolicy, always Deny, independent
# of Kyverno's mode): a Job or Pod in the namespace that references a job-scoped
# Secret (envFrom, env valueFrom, secret or projected volume) must carry the label
# dagster/job of a listed job, and must come from the run launcher (Job) or the
# Job controller (Pod). Run pods hold a ServiceAccount that may create Jobs and
# Pods, so a compromised ingestion run cannot mount the Secret itself.
locals {
  spec_refs = <<-CEL
    variables.ctrs.exists(c,
      c.?envFrom.orValue([]).exists(e, e.?secretRef.?name.orValue('') == variables.secret) ||
      c.?env.orValue([]).exists(e, e.?valueFrom.?secretKeyRef.?name.orValue('') == variables.secret)) ||
    variables.ps.?volumes.orValue([]).exists(v,
      v.?secret.?secretName.orValue('') == variables.secret ||
      v.?projected.?sources.orValue([]).exists(s, s.?secret.?name.orValue('') == variables.secret))
  CEL
  guard_kinds = {
    job = {
      resource_rules = [{ apiGroups = ["batch"], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["jobs"] }]
      podspec        = "object.spec.template.spec"
      labels         = "object.spec.template.metadata.?labels.orValue({})"
      creator        = "system:serviceaccount:${var.namespace}:${var.run_launcher_service_account}"
    }
    pod = {
      resource_rules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["pods", "pods/ephemeralcontainers"] }]
      podspec        = "object.spec"
      labels         = "object.metadata.?labels.orValue({})"
      creator        = "system:serviceaccount:kube-system:job-controller"
    }
  }
  job_secret_guards = merge([for name, secret in var.job_secrets : {
    for kind, k in local.guard_kinds : "${name}-${kind}" => merge(k, {
      secret = local.job_secret_names[name]
      jobs   = secret.jobs
      policy = "${var.namespace}-${local.job_secret_names[name]}-${kind}"
    })
  }]...)
}

resource "kubernetes_manifest" "job_secret_guard" {
  for_each = local.job_secret_guards
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = each.value.policy, labels = var.labels }
    spec = {
      failurePolicy    = "Fail"
      matchConstraints = { resourceRules = each.value.resource_rules }
      variables = [
        { name = "secret", expression = "'${each.value.secret}'" },
        { name = "ps", expression = each.value.podspec },
        { name = "ctrs", expression = "variables.ps.containers + variables.ps.?initContainers.orValue([]) + variables.ps.?ephemeralContainers.orValue([])" },
        { name = "refs", expression = local.spec_refs },
        { name = "job", expression = "${each.value.labels}[?'dagster/job'].orValue('')" },
      ]
      validations = [
        {
          expression = "!variables.refs || variables.job in ${jsonencode(each.value.jobs)}"
          message    = "Secret ${each.value.secret} may only be used by the Dagster jobs ${join(", ", each.value.jobs)} (label dagster/job)"
        },
        {
          expression = "!variables.refs || request.userInfo.username == '${each.value.creator}'"
          message    = "Secret ${each.value.secret} may only be referenced by objects created by ${each.value.creator}"
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "job_secret_guard_binding" {
  for_each = local.job_secret_guards
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = each.value.policy, labels = var.labels }
    spec = {
      policyName        = kubernetes_manifest.job_secret_guard[each.key].manifest.metadata.name
      validationActions = ["Deny"]
      matchResources = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.namespace } }
      }
    }
  }
}

# Admission guard for every run Job the launcher creates (audit R3-1): exactly the
# launcher's entrypoint (no command, args `dagster api execute_run|resume_run`),
# one container from the code location image, no init/ephemeral containers, the
# label dagster/job equal to the launcher-set DAGSTER_RUN_JOB_NAME, and only the
# Secrets of the platform contract. Complements the tag allowlist of the launcher.
locals {
  run_secrets = concat(
    [local.env_secret, local.pg_secret],
    var.compute_logs == null ? [] : [local.compute_logs_secret],
    values(local.job_secret_names),
  )
  run_job_checks = [
    {
      expression = "size(variables.ps.containers) == 1 && !has(variables.ps.initContainers) && !has(variables.ps.ephemeralContainers)"
      message    = "Dagster run Jobs have exactly one container and no init or ephemeral containers"
    },
    {
      expression = "variables.ctrs.all(c, !has(c.command) || size(c.command) == 0)"
      message    = "Dagster run Jobs may not override the container command"
    },
    {
      expression = "variables.ctrs.all(c, has(c.args) && size(c.args) >= 3 && c.args[0] == 'dagster' && c.args[1] == 'api' && c.args[2] in ['execute_run', 'resume_run'])"
      message    = "Dagster run Jobs must run the launcher's entrypoint (dagster api execute_run|resume_run)"
    },
    {
      expression = "variables.ctrs.all(c, c.image in ${jsonencode([var.code_location_image])})"
      message    = "Dagster run Jobs must use the deployed code location image"
    },
    {
      expression = "variables.job != '' && variables.ctrs.all(c, c.?env.orValue([]).exists(e, e.name == 'DAGSTER_RUN_JOB_NAME' && e.?value.orValue('') == variables.job))"
      message    = "label dagster/job must equal the launcher's DAGSTER_RUN_JOB_NAME"
    },
    {
      expression = <<-CEL
        variables.ctrs.all(c,
          c.?envFrom.orValue([]).all(e, !has(e.secretRef) || e.secretRef.name in variables.allowed) &&
          c.?env.orValue([]).all(e, !has(e.valueFrom) || !has(e.valueFrom.secretKeyRef) || e.valueFrom.secretKeyRef.name in variables.allowed)) &&
        variables.ps.?volumes.orValue([]).all(v, !has(v.secret) || v.secret.secretName in variables.allowed) &&
        variables.ps.?volumes.orValue([]).all(v, !has(v.projected))
      CEL
      message    = "Dagster run Jobs may only use the Secrets ${join(", ", local.run_secrets)}"
    },
  ]
}

resource "kubernetes_manifest" "run_job_guard" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = "${var.namespace}-dagster-run-jobs", labels = var.labels }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [{ apiGroups = ["batch"], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = ["jobs"] }]
      }
      matchConditions = [{
        name       = "created-by-the-run-launcher"
        expression = "request.userInfo.username == 'system:serviceaccount:${var.namespace}:${var.run_launcher_service_account}'"
      }]
      variables = [
        { name = "ps", expression = "object.spec.template.spec" },
        { name = "ctrs", expression = "object.spec.template.spec.containers" },
        { name = "job", expression = "object.spec.template.metadata.?labels.orValue({})[?'dagster/job'].orValue('')" },
        { name = "allowed", expression = jsonencode(local.run_secrets) },
      ]
      validations = local.run_job_checks
    }
  }
}

resource "kubernetes_manifest" "run_job_guard_binding" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = "${var.namespace}-dagster-run-jobs", labels = var.labels }
    spec = {
      policyName        = kubernetes_manifest.run_job_guard.manifest.metadata.name
      validationActions = ["Deny"]
      matchResources = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.namespace } }
      }
    }
  }
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
      env                    = local.system_env
      envSecrets             = local.system_env_secrets
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
      env                    = local.system_env
      envSecrets             = local.system_env_secrets
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

    # K8sRunLauncher through the chart's CustomRunLauncher: the chart has no value for
    # only_allow_user_defined_k8s_config_fields (audit R3-1). The allowlist is what
    # the code location's container context sets plus env_from for the purge tag;
    # a dagster-k8s/config run tag with anything else (command, args, image,
    # labels, init containers, ...) makes the launch fail. Env var names are limited
    # to the platform contract (only_allow_user_defined_env_vars).
    runLauncher = {
      type = "CustomRunLauncher"
      config = {
        customRunLauncher = {
          module = "dagster_k8s"
          class  = "K8sRunLauncher"
          config = {
            load_incluster_config    = true
            job_namespace            = var.namespace
            image_pull_policy        = "IfNotPresent"
            service_account_name     = var.run_launcher_service_account
            dagster_home             = "/opt/dagster/dagster_home"
            instance_config_map      = "${local.name}-instance"
            postgres_password_secret = module.db_credentials.secret_name
            resources                = var.resources["run"]
            fail_pod_on_run_failure  = true
            security_context         = local.container_sctx
            # common labels on run Jobs/pods come from the launcher, not from the
            # container context (labels are not allowed from tags)
            labels = var.labels
            run_k8s_config = {
              pod_spec_config            = { securityContext = local.pod_secctx, enableServiceLinks = false }
              pod_template_spec_metadata = { labels = { "app.kubernetes.io/name" = "dagster-run" } }
              job_spec_config            = { backoffLimit = 0, ttlSecondsAfterFinished = var.run_ttl_seconds }
            }
            only_allow_user_defined_k8s_config_fields = local.run_config_allowlist
            only_allow_user_defined_env_vars          = sort(keys(local.env_map))
          }
        }
      }
    }

    # compute logs: run pods always log to stdout (cluster log pipeline); with
    # var.compute_logs also to S3 (own bucket), readable in the Dagster UI
    computeLogManager = var.compute_logs == null ? { type = "NoOpComputeLogManager", config = {} } : {
      type = "S3ComputeLogManager"
      config = {
        s3ComputeLogManager = {
          bucket         = var.compute_logs.bucket
          prefix         = var.compute_logs.prefix
          endpointUrl    = var.compute_logs.endpoint_url
          verifyCertPath = local.ca_path
          skipEmptyFiles = true
        }
      }
    }

    concurrency = {
      enabled = true
      pools   = { granularity = "op" }
      runs    = { maxConcurrentRuns = var.max_concurrent_runs, tagConcurrencyLimits = [] }
    }
  })]

  depends_on = [kubernetes_manifest.solution_env, module.compute_logs_credentials]
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

  depends_on = [kubernetes_manifest.solution_env, module.compute_logs_credentials]
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
