# 31-policy: admission control and supply-chain policy.
#   - Kyverno (namespace kyverno)
#   - OpenBao transit key that signs the solution artefacts (cosign); the
#     private key never leaves OpenBao, the public key is read here and handed
#     to the image verification policy
#   - the policy set (modules/kyverno-policies)

provider "vault" {
  skip_child_token = true
}

locals {
  registry_ca_pem = file(coalesce(var.registry_ca_file, pathexpand("~/.boccob/${var.environment}/pki/registry-ca.crt")))
  registry_port   = length(split(":", var.registry_host)) > 1 ? tonumber(split(":", var.registry_host)[1]) : 443
  kyverno_ns      = "kyverno"
}

module "ns_kyverno" {
  source = "../../modules/namespace-baseline"
  name   = local.kyverno_ns
  labels = local.common_labels

  allow_kube_api = true
  ingress_rules = [
    {
      # kube-apiserver -> admission webhooks
      name       = "webhooks"
      from_cidrs = var.cluster_cidrs
      ports      = [9443]
    },
    {
      name            = "metrics"
      from_namespaces = var.metrics_namespaces
      ports           = [8000]
    },
  ]
  egress_rules = [
    {
      # image manifests and cosign signatures are read from the Zot mirror
      name     = "registry"
      to_cidrs = coalesce(var.registry_cidrs, var.cluster_cidrs)
      ports    = [local.registry_port]
    },
  ]
  # the controllers set their own resources
  limit_range = {}
}

locals {
  kyverno_image = { for k, key in {
    admission  = "kyverno"
    pre        = "kyverno-pre"
    background = "kyverno-background-controller"
    reports    = "kyverno-reports-controller"
    } : k => {
    registry   = module.versions.images[key].registry
    repository = module.versions.images[key].repository_path
    tag        = module.versions.images[key].tag_digest
  } }
  kyverno_pdb = { enabled = var.ha, minAvailable = 1 }
}

resource "helm_release" "kyverno" {
  name       = "kyverno"
  namespace  = module.ns_kyverno.name
  repository = module.versions.charts["kyverno"].repository
  chart      = module.versions.charts["kyverno"].name
  version    = module.versions.charts["kyverno"].version
  timeout    = 600
  atomic     = true

  values = [yamlencode({
    crds = {
      install = true
      # the CRD migration hook needs the kyverno-cli image and only matters when upgrading from old CRD versions
      migration = { enabled = false }
    }
    # hooks that need extra images (readiness-checker): the webhook
    # configurations are removed by the admission controller itself on shutdown
    webhooksCleanup = { enabled = false }
    config = {
      webhooks = {
        # kube-system stays excluded: it holds the k3s system pods the cluster needs to recover
        namespaceSelector = {
          matchExpressions = [{
            key      = "kubernetes.io/metadata.name"
            operator = "NotIn"
            values   = ["kube-system"]
          }]
        }
      }
    }
    # Kyverno fetches image signatures from the registry and must trust its CA
    global = { caCertificates = { data = local.registry_ca_pem } }
    features = {
      # PolicyExceptions are honoured only from Kyverno's own namespace
      policyExceptions = { enabled = true, namespace = module.ns_kyverno.name }
      backgroundScan   = { enabled = true, backgroundScanInterval = "1h" }
      logging          = { format = "json" }
    }
    admissionController = {
      replicas            = var.ha ? 3 : 1
      podDisruptionBudget = local.kyverno_pdb
      initContainer       = { image = local.kyverno_image["pre"] }
      container = {
        image     = local.kyverno_image["admission"]
        resources = var.kyverno_resources["admission"]
      }
    }
    backgroundController = {
      enabled             = var.kyverno_background_controller_enabled
      replicas            = var.ha ? 2 : 1
      podDisruptionBudget = local.kyverno_pdb
      image               = local.kyverno_image["background"]
      resources           = var.kyverno_resources["background"]
    }
    cleanupController = { enabled = false }
    reportsController = {
      replicas            = var.ha ? 2 : 1
      podDisruptionBudget = local.kyverno_pdb
      image               = local.kyverno_image["reports"]
      resources           = var.kyverno_resources["reports"]
    }
  })]
}

moved {
  from = module.kyverno.helm_release.this
  to   = helm_release.kyverno
}

# =============================================================================
# Signing key for the solution artefacts: OpenBao transit, never exportable.
# scripts/supply-chain/sign.sh signs with `cosign --key hashivault://<name>`.
# =============================================================================
resource "vault_mount" "transit" {
  path        = "transit"
  type        = "transit"
  description = "Signing keys (cosign) — keys are created non-exportable"

  # irreplaceable (all KV secrets incl. the pepper / the CA keys / the cosign key):
  # a change that forces replacement must fail instead of wiping it
  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_transit_secret_backend_key" "cosign" {
  backend          = vault_mount.transit.path
  name             = var.cosign_key_name
  type             = "ecdsa-p256"
  exportable       = false
  deletion_allowed = false

  # irreplaceable (all KV secrets incl. the pepper / the CA keys / the cosign key):
  # a change that forces replacement must fail instead of wiping it
  lifecycle {
    prevent_destroy = true
  }
}

# Release engineers / the publishing job get this policy: sign and read the
# public key, nothing else.
resource "vault_policy" "cosign_signer" {
  name   = "cosign-signer"
  policy = <<-EOT
    path "${vault_mount.transit.path}/keys/${var.cosign_key_name}" { capabilities = ["read"] }
    path "${vault_mount.transit.path}/sign/${var.cosign_key_name}" { capabilities = ["update"] }
    path "${vault_mount.transit.path}/sign/${var.cosign_key_name}/*" { capabilities = ["update"] }
    path "${vault_mount.transit.path}/verify/${var.cosign_key_name}" { capabilities = ["update"] }
    path "${vault_mount.transit.path}/verify/${var.cosign_key_name}/*" { capabilities = ["update"] }
  EOT
}

locals {
  # every key version stays valid for verification until it is trimmed in OpenBao
  cosign_public_keys = [for k in vault_transit_secret_backend_key.cosign.keys : k.public_key]

  # Exceptions for foundation workloads, each with its reason. Remove an entry
  # when the workload is fixed; `make verify` checks that they are honoured.
  builtin_exceptions = [
    {
      name          = "keycloak-writable-rootfs"
      policies      = ["require-read-only-root-filesystem"]
      namespaces    = [local.platform.namespaces.identity]
      name_prefixes = ["keycloak"]
      justification = "The upstream Keycloak image augments itself (Quarkus build) into its root filesystem at start; an optimised custom image is an open hardening item (docs/runbook-bootstrap.md)."
    },
    {
      name          = "rustfs-init-container-resources"
      policies      = ["require-requests-limits"]
      namespaces    = [local.platform.namespaces.storage]
      name_prefixes = ["rustfs"]
      justification = "The init container of the upstream RustFS chart has no resources block and no value to set one; the namespace LimitRange supplies defaults."
    },
    {
      name          = "log-collector-root"
      policies      = ["require-run-as-non-root"]
      namespaces    = ["observability-agent"]
      name_prefixes = ["otel-log-collector"]
      justification = "Reads root-owned node log files (/var/log/pods, API audit log) through read-only hostPath mounts; runs as uid 0 without any capability, no privilege escalation, read-only root filesystem."
    },
  ]
}

module "policies" {
  source                = "../../modules/kyverno-policies"
  namespace             = helm_release.kyverno.namespace
  registry_host         = var.registry_host
  mode                  = var.policy_mode
  failure_policy        = coalesce(var.policy_failure_policy, var.ha ? "Fail" : "Ignore")
  excluded_namespaces   = var.policy_excluded_namespaces
  policies              = var.policy_overrides
  signature_public_keys = local.cosign_public_keys
  signature_mode        = var.signature_mode
  keyless_policies      = var.keyless_policies
  exceptions            = concat(local.builtin_exceptions, var.policy_exceptions)
}
