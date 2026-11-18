variable "name" {
  description = "Name of the Kubernetes Secret (and of the ExternalSecret / PushSecret / generator objects)."
  type        = string
}

variable "namespace" {
  description = "Namespace (needs secrets_access = true in its namespace baseline)."
  type        = string
}

variable "kv_path" {
  description = "OpenBao KV v2 path (without mount), convention <namespace>/<name>, e.g. storage/rustfs-root."
  type        = string
}

variable "keys" {
  description = "Secret keys to generate randomly. Each key gets its own value."
  type        = list(string)
  default     = ["password"]
}

variable "length" {
  description = "Length of every generated value."
  type        = number
  default     = 40
}

variable "literals" {
  description = "Non-secret values stored next to the generated ones (usernames, client ids...)."
  type        = map(string)
  default     = {}
}

variable "push_store" {
  description = "ClusterSecretStore with write access to OpenBao."
  type        = string
  default     = "openbao-push"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}

variable "read_store" {
  description = "Secret store that reads OpenBao KV (materialises the consumed Secret)."
  type        = string
  default     = "openbao"
}

variable "store_kind" {
  description = "Kind of read_store / push_store: ClusterSecretStore (legacy cluster-wide stores) or SecretStore (per-namespace stores)."
  type        = string
  default     = "SecretStore"
}
