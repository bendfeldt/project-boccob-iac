openbao_replicas           = 3
openbao_data_storage_size  = "10Gi"
openbao_audit_storage_size = "10Gi"
openbao_resources = {
  requests = { cpu = "250m", memory = "512Mi" }
  limits   = { memory = "1Gi" }
}
