# dev: the off-site copy stand-in uses a second S3 user of the same RustFS
extra_namespace_secret_reads = {
  backup = ["storage/s3-users/platform-offsite"]
}
