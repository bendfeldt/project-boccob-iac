# audit-archive

Nightly export of the Loki audit tenant (previous UTC day) to an S3 bucket
created with object lock; NDJSON gzip + manifest with sha256 and the sha256 of
the previous manifest (hash chain). Exporter: python stdlib (TLS verified
against the platform CA); uploader: rc (SSE-S3). Verified on dev, see stack
30-observability README. Lines sharing the last nanosecond timestamp of a page
boundary could be skipped (cursor = last + 1 ns).
