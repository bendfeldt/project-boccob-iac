# 20-data-plane: placeholder — filled in by the next work package (Polaris, Trino + OPA, Dagster).
#
# Conventions (docs/conventions.md):
#   - namespaces through modules/namespace-baseline
#   - images/charts only through module.versions (versions.yaml -> make lock -> make airgap-mirror)
#   - certificates from ClusterIssuer local.platform.cluster_issuer
#   - secrets through modules/generated-secret / modules/external-secret
#   - databases through modules/postgres-cluster (namespace "database")
#   - OpenBao policies/roles with the vault provider (STACK_NEEDS_OPENBAO=1 in stack.env)

provider "vault" {
  skip_child_token = true
}

data "kubernetes_config_map_v1" "platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = local.platform.namespaces.platform
  }
}

locals {
  platform_ca_pem = data.kubernetes_config_map_v1.platform_ca.data["ca.crt"]
}
