# s3-mirror

CronJob that copies a bucket (or prefix) one-way to a second S3 target with
`rc mirror` (RustFS CLI, pinned in versions.yaml). Used for the off-site copy of
`platform-backup`.

- Several buckets per job, each below `<target bucket>/<prefix>/<bucket>/`.
- `propagate_deletes` per bucket: true for data that must be erasable (lake
  buckets: erasure/retention deletes reach the copy at the next run), false for
  backups (what reached the target stays until the target's own retention).
- The target should have versioning, object lock (COMPLIANCE) and default
  encryption configured by the off-site operator; this module does not manage it.
- Only current object versions are copied.
- Native RustFS bucket replication exists upstream but was not exercised here; this
  job works against any S3-compatible target.

```hcl
module "offsite_copy" {
  source    = "../../modules/s3-mirror"
  namespace = "backup"
  image     = module.versions.images["rustfs-rc"].ref
  source_s3 = { endpoint = local.platform.s3_url, credentials_secret = "platform-backup-s3", buckets = [{ name = "platform-backup" }, { name = "lakehouse-raw", propagate_deletes = true }] }
  target_s3 = { endpoint = "https://s3.offsite.example:443", bucket = "boccob-backup", credentials_secret = "offsite-s3" }
}
```
