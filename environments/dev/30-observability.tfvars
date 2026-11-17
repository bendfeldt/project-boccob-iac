# dev: tiny and short-lived. Grafana is off on the build machine (image ~480 MB,
# disk budget); the module is validated with `helm template` only.
log_retention_period    = "48h"
audit_retention_period  = "168h"
metrics_retention       = "1d"
metrics_retention_size  = "500MB"
loki_storage_size       = "1Gi"
prometheus_storage_size = "1Gi"
grafana_enabled         = false
