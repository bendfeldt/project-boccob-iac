# rustfs

RustFS (Apache-2.0, S3 compatible) from the upstream chart
(`charts.rustfs.com`, source `github.com/rustfs/rustfs/helm/rustfs`).

- dev: `distributed = false` — one pod, one volume
- HA: `distributed = true` — StatefulSet of `replicas` nodes x
  `drives_per_node` volumes, erasure coded, PDB, required anti-affinity
- native TLS on the S3 API and console (certificate from the platform PKI)
- root credentials generated in-cluster and stored in OpenBao
  (`kv/storage/rustfs-root`)
- buckets (versioning on by default), S3 users and bucket-scoped policies
  provisioned by an idempotent Job using the RustFS CLI `rc`; user secrets in
  OpenBao at `kv/storage/s3-users/<name>`

Verified upstream (README of rustfs/rustfs at 1.0.6): versioning, object
lock, bucket replication, site replication, lifecycle, SSE/KMS and IAM
policies are listed as available; S3 Tables (Iceberg REST) is preview and is
not used (Polaris is the catalog).

The pod runs non-root with a read-only root filesystem; logs go to stdout.
