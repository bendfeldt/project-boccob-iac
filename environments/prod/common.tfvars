# HA profile: multiple replicas, PDBs, topology spread. No secret values in tfvars — ever.
ha = true
# pod CIDR (k3s default) + node network: lets the API server reach admission webhooks
cluster_cidrs = ["10.42.0.0/16", "10.20.0.0/24"]
