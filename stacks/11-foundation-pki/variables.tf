variable "bootstrap_ca_pem" {
  description = "Public certificate of the bootstrap CA (signs OpenBao's listener certificate). Injected by scripts/tofu.sh."
  type        = string
}

variable "pki_extra_allowed_domains" {
  description = "Additional DNS domains the platform PKI may issue for (base_domain and cluster-internal names are always allowed)."
  type        = list(string)
  default     = []
}

variable "pki_max_leaf_ttl_hours" {
  description = "Maximum lifetime of issued leaf certificates."
  type        = number
  default     = 2160
}

variable "namespace_secret_stores" {
  description = "Per-namespace OpenBao access for the namespaced SecretStores (see modules/openbao-config namespace_stores). Each namespace reads kv/<ns>/* plus the listed cross-namespace paths and writes only kv/<ns>/*. Merged with extra_namespace_secret_reads."
  type = map(object({
    reads      = optional(list(string), [])
    deny_write = optional(list(string), [])
  }))
  default = {
    database      = { reads = ["storage/s3-users/platform-backup"] }
    storage       = {}
    identity      = { reads = ["database/keycloak-db"] }
    observability = { reads = ["storage/s3-users/platform-logs", "identity/oidc-clients/grafana", "identity/oidc-clients/grafana-audit"] }
    backup        = { reads = ["storage/s3-users/platform-backup"] }
    catalog       = { reads = ["database/polaris-db", "storage/s3-users/lakehouse-catalog"] }
    query = { reads = [
      "catalog/polaris/principals/trino",
      "identity/oidc-clients/trino",
      "identity/oidc-clients/trino-group-sync",
      "storage/s3-users/lakehouse-query",
    ] }
    orchestration = {
      reads = [
        "catalog/polaris/principals/ingest",
        "database/dagster-db",
        "identity/oidc-clients/dagster",
        "query/trino/service-accounts/svc-dagster",
        "storage/s3-users/lakehouse-orchestration",
        "storage/s3-users/lakehouse-purge",
      ]
      # written only by the pepper Job (its own OpenBao role, check-and-set 0)
      deny_write = ["orchestration/pseudonym-pepper"]
    }
  }
}

variable "extra_namespace_secret_reads" {
  description = "Additional cross-namespace reads per namespace (environment specific), e.g. { backup = [\"storage/s3-users/platform-offsite\"] } on dev."
  type        = map(list(string))
  default     = {}
}

variable "legacy_cluster_store_namespaces" {
  description = "Namespaces that may still use the cluster-wide ClusterSecretStores openbao / openbao-push (full kv/* access) until their ExternalSecrets/PushSecrets switch to the namespaced SecretStores. Empty (default, all namespaces migrated) = the ClusterSecretStores are not created."
  type        = list(string)
  default     = []
}
