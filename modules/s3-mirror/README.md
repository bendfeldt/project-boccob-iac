# s3-mirror

CronJob that copies buckets one-way to a second S3 target with `rc mirror`
(RustFS CLI, pinned in versions.yaml). Used by `stacks/32-backup` for the
off-site copy, with **one instance per target bucket**:

| Instance | Source | Target bucket (configured by the off-site operator) |
|---|---|---|
| `offsite-copy` | `platform-backup` (`propagate_deletes = false`) | versioning + object lock (COMPLIANCE) + default encryption: a compromised platform cannot destroy backups |
| `offsite-lake-copy` | the four lake buckets (`propagate_deletes = true`), S3 user `platform-offsite-reader` | **no object lock**; versioning only with a lifecycle rule that expires noncurrent versions within a few days (`target_guard`) |

Never put lake data into a locked target: on a versioned/locked bucket a
propagated delete only adds a delete marker, so erased raw files, Iceberg
files and erasure-queue files would stay retrievable (or undeletable) for the
lock period, out of reach of the solution's erasure. With `target_guard` set,
every run first reads the target's object lock, versioning and lifecycle
configuration and exits non-zero (`REFUSED: ...`, CronJob failure alert)
instead of copying when the target does not qualify.

- Several buckets per job, each below `<target bucket>/<prefix>/<bucket>/`.
- `propagate_deletes` per bucket: true for data that must be erasable (lake
  buckets: erasure/retention deletes reach the copy at the next run), false for
  backups (what reached the target stays until the target's own retention).
- Erasure reaches the lake copy after at most one run interval plus the
  target's noncurrent-version expiry.
- The module does not manage the target bucket's configuration.
- Only current object versions are copied.
- Native RustFS bucket replication exists upstream but was not exercised here; this
  job works against any S3-compatible target.

```hcl
module "offsite_copy" {           # backups -> locked target
  source    = "../../modules/s3-mirror"
  namespace = "backup"
  image     = module.versions.images["rustfs-rc"].ref
  source_s3 = { endpoint = local.platform.s3_url, credentials_secret = "platform-backup-s3", buckets = [{ name = "platform-backup" }] }
  target_s3 = { endpoint = "https://s3.offsite.example:443", bucket = "boccob-backup", credentials_secret = "offsite-s3" }
}

module "offsite_lake_copy" {      # lake -> unlocked target, checked before every run
  source       = "../../modules/s3-mirror"
  name         = "offsite-lake-copy"
  namespace    = "backup"
  image        = module.versions.images["rustfs-rc"].ref
  source_s3    = { endpoint = local.platform.s3_url, credentials_secret = "platform-offsite-reader-s3", buckets = [{ name = "lakehouse-raw", propagate_deletes = true }] }
  target_s3    = { endpoint = "https://s3.offsite.example:443", bucket = "boccob-lake", credentials_secret = "offsite-lake-s3" }
  target_guard = { max_noncurrent_days = 7 }
}
```
