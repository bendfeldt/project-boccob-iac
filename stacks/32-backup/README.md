# 32-backup

| What | How | Where |
|---|---|---|
| PostgreSQL (every CNPG cluster) | base backup daily + continuous WAL archive (PITR), gzip, SSE-S3 | `s3://platform-backup/postgres/<cluster>/` — configured on the cluster (`modules/postgres-cluster` `backup`, stack 12 `local.postgres_backup`) |
| OpenBao | raft snapshot CronJob (`openbao_snapshot_schedule`), SSE-S3 | `s3://platform-backup/openbao/raft-<ts>.snap` |
| Retention | barman `retentionPolicy` (PostgreSQL); S3 lifecycle: snapshots `openbao_snapshot_retention_days`, noncurrent versions `noncurrent_version_retention_days` | bucket `platform-backup` (versioned) |
| Off-site copy, backups | CronJob `offsite-copy`: `platform-backup` -> `offsite.bucket` (no delete propagation; the target should have versioning + object lock COMPLIANCE) | variable `offsite`, target credentials `kv/backup/offsite-s3`, source user `platform-backup` (own bucket only) |
| Off-site copy, lake | CronJob `offsite-lake-copy`: the four lakehouse buckets -> a **separate** bucket `offsite.lake.bucket`, deletions propagated; every run first refuses a target with object lock or without noncurrent-version expiry <= `offsite.lake.max_noncurrent_days` (default 7) | target credentials `kv/backup/offsite-lake-s3`; source user `platform-offsite-reader` (read only on the lake buckets, readable only from namespace `backup`) |
| k3s datastore | etcd snapshots on HA servers (`scripts/lib/k3s-config.sh`) | `/var/lib/rancher/k3s/server/db/snapshots` (+ optional S3) |
| Targets | `rpo_minutes`, `rto_minutes` (documented; alerts and `make restore-test` measure against them) | |

Off-site copy and erasure: the lake copy is in the erasure scope. An erased
object disappears from the copy at the next `offsite-lake-copy` run (default
every 6 h) and its noncurrent version at the target after
`offsite.lake.max_noncurrent_days` at most; the target therefore must not have
object lock (the CronJob refuses one). Backups keep their lock and are
handled by re-applying erasures after a restore (runbook disaster-recovery).
`make verify` runs the lake copy once and checks the target and the source
user.

Namespace `backup` (PSS restricted, default deny; egress OpenBao 8200, S3 9000,
PostgreSQL 5432, off-site target). Scripts: `make backup|restore|restore-test ENV=..`
(scripts/backup/). Runbook: docs/compliance/runbooks/disaster-recovery.md.

Other database owners: pass to `modules/postgres-cluster`
```hcl
backup = {
  destination_path   = "s3://platform-backup/postgres"
  endpoint_url       = local.platform.s3_url
  credentials_secret = "platform-backup-s3"   # created in namespace database by stack 12
  ca_secret          = "platform-ca"          # Secret (not ConfigMap) created by stack 12
  encryption         = "AES256"
}
```
