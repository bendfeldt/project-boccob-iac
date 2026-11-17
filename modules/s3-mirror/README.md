# s3-mirror

CronJob that copies a bucket (or prefix) one-way to a second S3 target with
`rc mirror` (RustFS CLI, pinned in versions.yaml). Used for the off-site copy of
`platform-backup`.

- Deletions are not propagated (the mirror runs without its delete option): what
  reached the target stays there until the target's own retention removes it.
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
  source_s3 = { endpoint = local.platform.s3_url, bucket = "platform-backup", credentials_secret = "platform-backup-s3" }
  target_s3 = { endpoint = "https://s3.offsite.example:443", bucket = "boccob-backup", credentials_secret = "offsite-s3" }
}
```
