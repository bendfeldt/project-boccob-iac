output "root_ca_pem" {
  description = "Root CA certificate (public)."
  value       = vault_pki_secret_backend_root_cert.root.certificate
}

output "issuing_ca_pem" {
  description = "Issuing (intermediate) CA certificate (public)."
  value       = vault_pki_secret_backend_root_sign_intermediate.int.certificate
}

output "pki_sign_path" {
  description = "Path cert-manager signs CSRs with."
  value       = "${vault_mount.pki_int.path}/sign/${vault_pki_secret_backend_role.platform.name}"
}

output "kubernetes_auth_path" {
  description = "Mount path of the kubernetes auth method."
  value       = vault_auth_backend.kubernetes.path
}

output "kv_mount" {
  description = "KV v2 mount path."
  value       = vault_mount.kv.path
}

output "roles" {
  description = "Kubernetes auth role names."
  value = {
    cert_manager = vault_kubernetes_auth_backend_role.cert_manager.role_name
    eso_read     = var.legacy_eso_roles ? vault_kubernetes_auth_backend_role.eso_read[0].role_name : null
    eso_push     = var.legacy_eso_roles ? vault_kubernetes_auth_backend_role.eso_push[0].role_name : null
  }
}
