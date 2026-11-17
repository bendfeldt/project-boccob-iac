output "configmap" {
  description = "ConfigMap to mount at /truststore-src in the init container."
  value       = kubernetes_config_map_v1.this.metadata[0].name
}

output "command" {
  description = "Init container command (image must contain sh and keytool, JAVA_HOME set)."
  value       = ["sh", "/truststore-src/build.sh"]
}

output "path" {
  description = "Trust store path inside the pod (emptyDir mounted at /truststore)."
  value       = "/truststore/cacerts"
}

output "jvm_flags" {
  description = "JVM flags that select the trust store."
  value       = ["-Djavax.net.ssl.trustStore=/truststore/cacerts", "-Djavax.net.ssl.trustStorePassword=changeit"]
}

output "checksum" {
  description = "Changes when the CA bundle changes (use as a pod annotation to roll the workload)."
  value       = sha256(var.ca_bundle_pem)
}
