# JVMs only accept JKS/PKCS12 trust stores for the default SSL context (S3
# client, JDBC, OIDC discovery). This module prepares what an init container of
# the workload's own image needs to build one: the platform CA bundle split
# into single certificates (keytool imports one certificate per call) and a
# script that copies the JRE's cacerts and adds them.
#
# Usage in a pod: init container running `sh /truststore-src/build.sh` with the
# ConfigMap mounted at /truststore-src and an emptyDir at /truststore, then
# -Djavax.net.ssl.trustStore=/truststore/cacerts (password "changeit": the
# store only holds public certificates).

locals {
  certs  = regexall("-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----", var.ca_bundle_pem)
  script = <<-SH
    set -eu
    cp "$JAVA_HOME/lib/security/cacerts" /truststore/cacerts
    chmod 644 /truststore/cacerts
    for f in /truststore-src/*.crt; do
      keytool -importcert -noprompt -trustcacerts -alias "platform-$(basename "$f" .crt)" \
        -file "$f" -keystore /truststore/cacerts -storepass changeit >/dev/null
    done
    echo "truststore ready: $(ls /truststore-src/*.crt | wc -l) platform CA certificate(s) added"
  SH
}

resource "kubernetes_config_map_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = var.labels
  }
  data = merge(
    { "build.sh" = local.script },
    { for i, cert in local.certs : "ca-${i}.crt" => "${cert}\n" },
  )
}
