variable "name" {
  description = "Ingress name."
  type        = string
}

variable "namespace" {
  description = "Namespace of the backend Service."
  type        = string
}

variable "host" {
  description = "Fully qualified hostname, convention <svc>.<base_domain>."
  type        = string
}

variable "service_name" {
  description = "Backend Service name."
  type        = string
}

variable "service_port" {
  description = "Backend Service port number."
  type        = number
}

variable "path" {
  description = "Path prefix routed to the backend."
  type        = string
  default     = "/"
}

variable "backend_tls" {
  description = "Backend speaks HTTPS with a certificate from the platform CA: Traefik then verifies it (ServersTransport with the namespace's platform-ca ConfigMap and this server name). null = plain HTTP backend."
  type = object({
    server_name  = string
    ca_configmap = optional(string, "platform-ca")
  })
  default = null
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer for the ingress certificate."
  type        = string
  default     = "openbao-pki"
}

variable "ingress_class" {
  description = "IngressClass."
  type        = string
  default     = "traefik"
}

variable "annotations" {
  description = "Extra Ingress annotations (e.g. Traefik middlewares)."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}
