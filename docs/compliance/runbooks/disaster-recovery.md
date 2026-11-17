# Runbook: backup and disaster recovery

## Targets

`rpo_minutes` (default 60) and `rto_minutes` (default 240) in
`stacks/32-backup` are documented targets; the organisation must set them
from its business impact analysis **[manual]**. What the mechanisms give:

| Data | Mechanism | Achievable RPO | Measured restore time |
|---|---|---|---|
| PostgreSQL (every CNPG cluster with `backup`) | daily base backup + continuous WAL archive (archive_timeout 5 min), SSE-S3, `s3://platform-backup/postgres/<cluster>/` | minutes | dev: 34 s for keycloak-db (PITR into a scratch cluster) **[verified]** |
| OpenBao | raft snapshot CronJob (`openbao_snapshot_schedule`, default hourly), `s3://platform-backup/openbao/` | schedule interval | snapshot integrity checked by `make restore-test` **[verified]**; full restore **[static]** |
| Object storage (layer buckets) | versioning on all contract buckets; Iceberg snapshots; off-site copy of `platform-backup` (`offsite`) | — | **[static]**: lake data itself is not copied off-site by default (size); add buckets to an off-site copy or use RustFS replication on a second site |
| Audit trail | Loki (`platform-logs`, versioned) + WORM archive `platform-audit` (daily) | 1 day for the archive | **[verified]** archive written and locked |
| Cluster state (k3s datastore) | etcd snapshots on HA servers every 6 h, 28 kept (`scripts/lib/k3s-config.sh`) | 6 h | **[static]** |
| Configuration | git (both repositories) + `versions.lock.yaml` + Zot | — | redeploy with `make deploy` |

Retention: PostgreSQL `retention_policy` (stack 12 `postgres_backup`, default 7d),
OpenBao snapshots `openbao_snapshot_retention_days`, deleted versions
`noncurrent_version_retention_days` (S3 lifecycle, applied by the snapshot job).

## Regular test

`make restore-test ENV=<env>` — base backup, marker row written after it,
point-in-time recovery into `restore-test-<ts>`, table count + marker
compared, scratch cluster removed; newest OpenBao snapshot downloaded and
checked (recorded sha256, archive structure, internal SHA256SUMS, raft index).
It also runs as part of `make verify` (`VERIFY_RESTORE_TEST=0` skips it).
Run it at least monthly on test/prod and keep the output **[manual: cadence]**.

## Scenarios

### A. One database lost or corrupted
1. `make restore WHAT=postgres CLUSTER=<name> TO=<name>-restored [TIME=2026-01-31T10:00:00Z] ENV=<env>`
   (new cluster; the old one is untouched).
2. Verify the data, then switch consumers: point them to `<name>-restored-rw`
   (Secret `<name>-restored-app`) or rename by restoring again under the
   original name after deleting the broken cluster. Re-enable `backup` on the
   new cluster (its WAL archive must go to a new `serverName`/path). **[static]**

### B. OpenBao data lost
1. If the pods are healthy but data is wrong: `CONFIRM=<env> make restore WHAT=openbao [KEY=openbao/raft-….snap] ENV=<env>` with a token holding sudo on `sys/storage/raft/snapshot`.
2. If the cluster is gone: deploy stack 10, `make openbao-init` **must not**
   initialise a new barrier for a restore — initialise, then force-restore the
   snapshot (`bao operator raft snapshot restore -force`) and unseal with the
   **old** unseal keys (key custody!). **[static]**
3. `make verify`; ESO and cert-manager reconnect automatically.

### C. Object storage lost
Restore from the off-site target with `rc mirror` in the opposite direction
(`modules/s3-mirror` with source/target swapped), then PostgreSQL/OpenBao
restores from `platform-backup`. **[static]**

### D. Whole site lost
1. New hosts → `make cluster-up` (node bundle, air-gap) → Zot from the bundle (`make airgap-load`).
2. `make deploy` stacks 00–12 (OpenBao: scenario B with the old keys first; OpenTofu state: from the etcd snapshot or re-import).
3. Restore `platform-backup` from off-site (C), PostgreSQL clusters (A), data plane, `make verify`.
4. Re-apply erasure requests executed after the backup date (erasure log in the solution repo) **[DPO/legal review]**.

Prerequisites kept outside the site: off-site copy, unseal key shares, state
passphrase, registry CA, a checkout of both repositories, the air-gap bundle.
