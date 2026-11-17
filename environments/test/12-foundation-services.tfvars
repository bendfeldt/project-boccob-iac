postgres_instances    = 3
postgres_storage_size = "10Gi"
postgres_resources = {
  requests = { cpu = "250m", memory = "1Gi" }
  limits   = { memory = "2Gi" }
}

rustfs_distributed       = true
rustfs_replicas          = 4
rustfs_drives_per_node   = 4
rustfs_data_storage_size = "100Gi"
rustfs_resources = {
  requests = { cpu = "1", memory = "4Gi" }
  limits   = { memory = "8Gi" }
}

keycloak_replicas = 2
keycloak_resources = {
  requests = { cpu = "500m", memory = "1536Mi" }
  limits   = { memory = "2Gi" }
}
