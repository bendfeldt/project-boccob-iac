output "platform_ca_pem" {
  description = "Internal CA bundle (public certificates): PKI root, issuing CA, bootstrap CA."
  value       = local.platform_ca_pem
}

output "cluster_issuer" {
  description = "cert-manager ClusterIssuer backed by the OpenBao PKI."
  value       = local.platform.cluster_issuer
}
