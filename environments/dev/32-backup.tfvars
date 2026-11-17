# dev: short retention; off-site copy into a second bucket of the same RustFS
# (stand-in for a real second site; credentials of the S3 user platform-offsite).
openbao_snapshot_retention_days   = 3
noncurrent_version_retention_days = 2
offsite = {
  endpoint    = "https://rustfs-svc.storage.svc:9000"
  bucket      = "platform-backup-offsite"
  credentials = "storage/s3-users/platform-offsite"
  namespaces  = ["storage"]
  port        = 9000
}
