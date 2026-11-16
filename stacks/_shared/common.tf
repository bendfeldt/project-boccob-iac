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
    openbao_url   = "https://openbao.secrets.svc:8200"
    keycloak_url  = "https://keycloak.${var.base_domain}"
    oidc_issuer   = "https://keycloak.${var.base_domain}/realms/lakehouse"
    s3_url        = "https://rustfs.storage.svc:9000"
    s3_region     = "us-east-1"
    ingress_class = "traefik"
  }

  common_labels = {
    "app.kubernetes.io/part-of"    = "boccob-lakehouse"
    "app.kubernetes.io/managed-by" = "opentofu"
    "boccob.io/environment"        = var.environment
  }
}
