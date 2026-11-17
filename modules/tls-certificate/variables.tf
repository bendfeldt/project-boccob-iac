variable "name" {
  description = "Name of the Certificate and of the resulting TLS Secret (tls.crt, tls.key, ca.crt)."
  type        = string
}

variable "namespace" {
  description = "Namespace."
  type        = string
}

variable "dns_names" {
  description = "Subject alternative names. The PKI role only signs <svc>.<namespace>.svc[.cluster.local] and names under the base domain."
  type        = list(string)
}

variable "usages" {
  description = "Key usages."
  type        = list(string)
  default     = ["server auth"]
}

variable "key_algorithm" {
  description = "Private key algorithm (RSA 2048 or ECDSA 256)."
  type        = string
  default     = "RSA"
}

variable "key_encoding" {
  description = "Private key encoding: PKCS1 or PKCS8 (Java servers need PKCS8)."
  type        = string
  default     = "PKCS8"
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer."
  type        = string
  default     = "openbao-pki"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
