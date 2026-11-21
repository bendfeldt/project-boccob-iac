# Shared by every stack through a symlink (stacks/<stack>/_common.tf).
# Do not put stack specific code here.

terraform {
  # State lives in Kubernetes Secrets (namespace tofu-state), one per stack and
  # environment; additionally encrypted client-side (TF_ENCRYPTION, see
  # scripts/tofu.sh). Backend settings are injected by scripts/tofu.sh.
  backend "kubernetes" {}
}

# --- inputs set by scripts/tofu.sh from environments/<env>/env.sh --------------
variable "environment" {
  description = "Environment name (dev|test|prod)."
  type        = string
}

variable "base_domain" {
  description = "Ingress hostnames are <svc>.<base_domain>."
  type        = string
}

variable "registry_host" {
  description = "Zot registry host[:port] holding all mirrored images and charts."
  type        = string
}

variable "public_https_port" {
  description = "Port of the public https URLs (<svc>.<base_domain>[:port]): 443 (default; Linux dev, test/prod, macOS with the pf redirect of make macos-ports) or a non-privileged port such as 8443 (macOS without the redirect). Keycloak's hostname, the OIDC issuer, redirect URIs and the Traefik entry points follow it. Set by scripts/tofu.sh from DEV_PUBLIC_HTTPS_PORT."
  type        = number
  default     = 443
  validation {
    condition     = var.public_https_port == 443 || (var.public_https_port >= 1024 && var.public_https_port <= 65535)
    error_message = "public_https_port must be 443 or a port from 1024 to 65535."
  }
}

variable "public_http_port" {
  description = "Port of the plain-http entry point (redirects to https): 80, or e.g. 8080 together with public_https_port = 8443."
  type        = number
  default     = 80
}

variable "cluster_arch" {
  description = "CPU architecture of the cluster nodes (amd64 = x64/x86_64, arm64 = aarch64). Set by scripts/tofu.sh from CLUSTER_ARCH; selects the image digests."
  type        = string
  default     = "amd64"
}

variable "kubeconfig_path" {
  description = "Path of the kubeconfig for the target cluster."
  type        = string
}

# --- inputs from environments/<env>/common.tfvars -------------------------------
variable "ha" {
  description = "HA profile: multiple replicas, PodDisruptionBudgets, topology spread. false = minimal single replicas (dev)."
  type        = bool
  default     = false
}

variable "cluster_cidrs" {
  description = "Pod and node network CIDRs. Used where the API server must reach admission webhooks behind default-deny NetworkPolicies."
  type        = list(string)
  default     = ["10.42.0.0/16"]
}

variable "lakehouse_noncurrent_version_days" {
  description = "Days after which noncurrent (deleted or overwritten) object versions in the four lakehouse buckets are removed by the RustFS lifecycle scanner; expired delete markers are removed too. This is the delayed-deletion safety window: an accidental DROP TABLE ... purge, a faulty job or a compromised credential without DeleteObjectVersion can be undone within it. It does not delay erasure: the erasure job deletes the object versions of the objects it touched explicitly (purge credential); it bounds how long data removed by ordinary deletes (retention, Iceberg maintenance) stays recoverable. Minimum 1 (S3 lifecycle granularity is days). Shared by stack 12 (bucket lifecycle) and stack 22 (NONCURRENT_VERSION_GRACE_DAYS: the solution purges only versions older than this, except an erasure's own objects); set it in environments/<env>/common.tfvars. Default 7 (docs/data-plane.md, \"Purge credential and deletion safety window\")."
  type        = number
  default     = 7
  validation {
    condition     = var.lakehouse_noncurrent_version_days >= 1
    error_message = "lakehouse_noncurrent_version_days must be at least 1."
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}

module "versions" {
  source        = "../../modules/versions"
  registry_host = var.registry_host
  arch          = var.cluster_arch
}

locals {
  # Keycloak (hostname v2) wants ONE fixed public URL incl. a non-default port; every
  # public https URL of the platform carries the same suffix
  public_port = var.public_https_port == 443 ? "" : ":${var.public_https_port}"
}

locals {
  # Well-known names: the contract between stacks. Stacks never read each
  # other's state; they rely on these names (documented in docs/conventions.md).
  platform = {
    namespaces = {
      platform      = "platform-system"
      secrets       = "secrets"
      identity      = "identity"
      storage       = "storage"
      database      = "database"
      catalog       = "catalog"
      query         = "query"
      orchestration = "orchestration"
      observability = "observability"
      registry      = "registry"
    }
    # cert-manager ClusterIssuers
    bootstrap_issuer = "bootstrap-ca" # only for OpenBao's own listener certificate
    cluster_issuer   = "openbao-pki"  # everything else
    # External Secrets ClusterSecretStores
    secret_store      = "openbao"      # read  kv/*
    secret_store_push = "openbao-push" # write kv/* (generated secrets)
    kv_mount          = "kv"
    # ConfigMap with the internal CA bundle (key ca.crt); source of truth in
    # platform-system, copied into namespaces by modules/namespace-baseline
    ca_configmap = "platform-ca"
    # in-cluster endpoints
    openbao_url  = "https://openbao.secrets.svc:8200"
    keycloak_url = "https://keycloak.${var.base_domain}${local.public_port}"
    oidc_issuer  = "https://keycloak.${var.base_domain}${local.public_port}/realms/lakehouse"
    # ":<port>" in public URLs when public_https_port is not 443, else ""
    public_port   = local.public_port
    s3_url        = "https://rustfs-svc.storage.svc:9000"
    s3_region     = "us-east-1"
    ingress_class = "traefik"
  }

  common_labels = {
    "app.kubernetes.io/part-of"    = "boccob-lakehouse"
    "app.kubernetes.io/managed-by" = "opentofu"
    "boccob.io/environment"        = var.environment
  }
}
