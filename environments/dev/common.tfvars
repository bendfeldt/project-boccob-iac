# dev: minimal single replicas. No secret values in tfvars — ever.
ha = false
# pod CIDR + podman network of the k3s node container
cluster_cidrs = ["10.42.0.0/16", "10.89.0.0/16"]
