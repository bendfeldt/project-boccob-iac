variable "namespace" {
  description = "Namespace (convention: storage; needs secrets_access = true)."
  type        = string
}

variable "chart" {
  description = "Chart coordinates from module.versions.charts[\"rustfs\"]."
  type = object({
    repository = string
    name       = string
    version    = string
  })
}

variable "images" {
  description = "Images from module.versions.images: rustfs, init (busybox), rc (RustFS CLI for provisioning)."
  type = map(object({
    repository = string
    tag_digest = string
    ref        = string
  }))
}

variable "distributed" {
  description = "false = single node, single drive (dev). true = distributed erasure-coded cluster (HA)."
  type        = bool
  default     = false
}

variable "replicas" {
  description = "Nodes in distributed mode (>= 4 recommended; the chart supports 4, 8, 16 style layouts)."
  type        = number
  default     = 4
}

variable "drives_per_node" {
  description = "Data volumes per node in distributed mode."
  type        = number
  default     = 1
}

variable "data_storage_size" {
  description = "Size of each data volume."
  type        = string
  default     = "5Gi"
}

variable "storage_class" {
  description = "StorageClass for data volumes."
  type        = string
  default     = "local-path"
}

variable "resources" {
  description = "Resources per RustFS pod."
  type        = any
  default     = { requests = { cpu = "50m", memory = "256Mi" }, limits = { memory = "1Gi" } }
}

variable "region" {
  description = "S3 region name reported by RustFS."
  type        = string
  default     = "us-east-1"
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer for the server certificate."
  type        = string
  default     = "openbao-pki"
}

variable "ca_configmap" {
  description = "ConfigMap in the namespace with the platform CA bundle (key ca.crt)."
  type        = string
  default     = "platform-ca"
}

variable "buckets" {
  description = <<-EOT
    Buckets to create (idempotent). versioning = true enables S3 object versioning.
    object_lock = { mode = "compliance"|"governance", days } creates the bucket
    with S3 object lock (only possible at creation: an existing bucket without
    lock is NOT converted) and sets the default retention; with compliance no
    one, including the RustFS root user, can delete a locked object version
    before it expires (verified on RustFS 1.0.6).
    lifecycle = { noncurrent_days, expired_delete_markers, expiration_days }
    expires noncurrent versions (needed wherever deletions must become final,
    e.g. GDPR erasure) and/or current objects after expiration_days (retention
    of log buckets).
  EOT
  type = map(object({
    versioning = optional(bool, true)
    object_lock = optional(object({
      mode = string
      days = number
    }))
    # Lifecycle (replaces the bucket's whole lifecycle configuration on every
    # provisioning run). noncurrent_days: delete overwritten/deleted object
    # versions after N days; expired_delete_markers: remove delete markers that
    # no longer hide any version. Evaluated by the RustFS scanner (1-day granularity).
    lifecycle = optional(object({
      noncurrent_days        = optional(number)
      expired_delete_markers = optional(bool, true)
      expiration_days        = optional(number) # delete current objects after N days (log buckets)
    }))
  }))
  default = {}
}

variable "users" {
  description = <<-EOT
    S3 users (static access keys) with bucket-scoped policies. The access key
    is the map key, the secret key is generated in-cluster and stored in
    OpenBao at kv/storage/s3-users/<name> (properties access-key, secret-key).
  EOT
  type = map(object({
    read_write_buckets = optional(list(string), [])
    read_only_buckets  = optional(list(string), [])
    purge_buckets      = optional(list(string), []) # list/get/delete objects and object versions only
  }))
  default = {}
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}

variable "sse_master_key_secret" {
  description = "Secret (name, key) holding a base64-encoded 32-byte master key for SSE-S3 (RUSTFS_SSE_S3_MASTER_KEY). Without it (and without a KMS) RustFS rejects requests that ask for server-side encryption. null = SSE-S3 not available."
  type = object({
    name = string
    key  = string
  })
  default = null
}

variable "secret_stores" {
  description = "External Secrets stores used for the generated credentials: { read, push, kind }. Default = the namespace's own SecretStores; pass module.ns_x.secret_stores for the namespace's own SecretStores."
  type = object({
    read = string
    push = string
    kind = string
  })
  default = { read = "openbao", push = "openbao-push", kind = "SecretStore" }
}
