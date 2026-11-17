variable "name" {
  description = "Name of the ConfigMap holding the split CA certificates and the import script."
  type        = string
  default     = "java-truststore"
}

variable "namespace" {
  description = "Namespace of the Java workload."
  type        = string
}

variable "ca_bundle_pem" {
  description = "PEM bundle of the platform CA(s) (ConfigMap platform-ca, key ca.crt)."
  type        = string
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
