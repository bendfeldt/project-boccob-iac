# java-truststore

Prepares a JVM trust store (JRE `cacerts` + platform CA) for Java workloads
(Polaris, Trino). Creates a ConfigMap with the CA bundle split into single
certificates and a `build.sh`; the workload runs it in an init container of its
own image and starts with `module.x.jvm_flags`.

```hcl
module "truststore" {
  source        = "../java-truststore"
  namespace     = var.namespace
  ca_bundle_pem = var.ca_bundle_pem
}
# init container: command = module.truststore.command
#   mounts: ConfigMap module.truststore.configmap -> /truststore-src, emptyDir -> /truststore
# main container: emptyDir -> /truststore (read-only), JVM flags module.truststore.jvm_flags
```
