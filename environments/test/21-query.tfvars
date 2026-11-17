# opa_bundle_ref = "registry.<env>.lakehouse.internal:5000/boccob/opa-policy-bundle@sha256:<digest>"   # required
# registry_cidrs = ["<registry host address>/32"]                                                    # required
trino_workers = 2
trino_worker_autoscaling = {
  enabled      = true
  max_replicas = 6
}
trino_coordinator = {
  heap                      = "12G"
  query_max_memory          = "40GB"
  query_max_memory_per_node = "6GB"
  resources                 = { requests = { cpu = "2", memory = "16Gi" }, limits = { memory = "16Gi" } }
}
