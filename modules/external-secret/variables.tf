variable "name" {
  description = "Name of the ExternalSecret and of the resulting Kubernetes Secret."
  type        = string
}

variable "namespace" {
  description = "Namespace (needs secrets_access = true in its namespace baseline)."
  type        = string
}

variable "kv_path" {
  description = "OpenBao KV v2 path (without mount) to read, e.g. database/keycloak-db."
  type        = string
}

variable "template" {
  description = "Optional Secret template: map of target key => Go template over the remote properties (e.g. { url = \"postgresql://{{ .username }}:{{ .password }}@{{ .host }}/{{ .dbname }}\" }). Empty = copy all properties 1:1."
  type        = map(string)
  default     = {}
}

variable "refresh_interval" {
  description = "How often the Secret is re-read from OpenBao."
  type        = string
  default     = "5m0s"
}

variable "store" {
  description = "ClusterSecretStore with read access to OpenBao."
  type        = string
  default     = "openbao"
}

variable "secret_type" {
  description = "Type of the resulting Secret."
  type        = string
  default     = "Opaque"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}

variable "store_kind" {
  description = "ClusterSecretStore (legacy cluster-wide store, full kv/* read) or SecretStore (the namespace's own store from modules/namespace-baseline, kv/<ns>/* + granted reads)."
  type        = string
  default     = "ClusterSecretStore"
}
