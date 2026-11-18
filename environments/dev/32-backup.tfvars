# dev: short retention; off-site copy into two buckets of the same RustFS
# (stand-in for a real second site): backups -> platform-backup-offsite (S3 user
# platform-offsite), lake -> platform-lake-offsite (S3 user platform-offsite-lake;
# no object lock, noncurrent versions expire after 1 day).
openbao_snapshot_retention_days   = 3
noncurrent_version_retention_days = 2
offsite = {
  endpoint    = "https://rustfs-svc.storage.svc:9000"
  bucket      = "platform-backup-offsite"
  credentials = "storage/s3-users/platform-offsite"
  namespaces  = ["storage"]
  port        = 9000
  lake = {
    bucket              = "platform-lake-offsite"
    credentials         = "storage/s3-users/platform-offsite-lake"
    max_noncurrent_days = 1
  }
}
