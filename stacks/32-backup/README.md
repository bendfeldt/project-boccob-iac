# 32-backup

| What | How | Where |
|---|---|---|
| PostgreSQL (every CNPG cluster) | base backup daily + continuous WAL archive (PITR), gzip, SSE-S3 | `s3://platform-backup/postgres/<cluster>/` — configured on the cluster (`modules/postgres-cluster` `backup`, stack 12 `local.postgres_backup`) |
| OpenBao | raft snapshot CronJob (`openbao_snapshot_schedule`), SSE-S3 | `s3://platform-backup/openbao/raft-<ts>.snap` |
| Retention | barman `retentionPolicy` (PostgreSQL); S3 lifecycle: snapshots `openbao_snapshot_retention_days`, noncurrent versions `noncurrent_version_retention_days` | bucket `platform-backup` (versioned) |
| Off-site copy | `rc mirror` CronJob to the S3 target in `offsite` (null = off) | variable `offsite`, credentials `kv/backup/offsite-s3` |
| k3s datastore | etcd snapshots on HA servers (`scripts/lib/k3s-config.sh`) | `/var/lib/rancher/k3s/server/db/snapshots` (+ optional S3) |
| Targets | `rpo_minutes`, `rto_minutes` (documented; alerts and `make restore-test` measure against them) | |

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
