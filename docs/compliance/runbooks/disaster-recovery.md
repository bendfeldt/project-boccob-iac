# Runbook: backup and disaster recovery

## Targets

`rpo_minutes` (default 60) and `rto_minutes` (default 240) in
`stacks/32-backup` are documented targets; the organisation must set them
from its business impact analysis **[manual]**. What the mechanisms give:

| Data | Mechanism | Achievable RPO | Measured restore time |
|---|---|---|---|
| PostgreSQL (every CNPG cluster with `backup`) | daily base backup + continuous WAL archive (archive_timeout 5 min), SSE-S3, `s3://platform-backup/postgres/<cluster>/` | minutes | dev: 34 s for keycloak-db (PITR into a scratch cluster) **[verified]** |
| OpenBao | raft snapshot CronJob (`openbao_snapshot_schedule`, default hourly), `s3://platform-backup/openbao/` | schedule interval | snapshot integrity checked by `make restore-test` **[verified]**; full restore **[static]** |
| Object storage (layer buckets) | Iceberg snapshots (time travel within their expiry); off-site copy of the four lakehouse buckets to their own unlocked target bucket (`offsite.lake`, stack 32; deletions propagated so erasure reaches the copy) and of `platform-backup` to a locked target (`offsite.bucket`); noncurrent versions expire after `lakehouse_noncurrent_version_days` | off-site schedule (default 6 h) | dev: 746 lake objects copied to the stand-in target in 23 s **[verified]**; restore from it **[static]** |
| Audit trail | Loki (`platform-logs`, versioned) + WORM archive `platform-audit` (daily) | 1 day for the archive | **[verified]** archive written and locked |
| Cluster state (k3s datastore) | etcd snapshots on HA servers every 6 h, 28 kept, prod also copied to an off-site S3 target (`K3S_ETCD_S3_CONFIG_SECRET`, `scripts/lib/k3s-config.sh`) | 6 h | **[static]** |
| OpenTofu state | test/prod: S3 bucket outside the site (`TOFU_STATE_S3_*`, `scripts/tofu.sh`), AES-GCM encrypted; dev: `~/.boccob/dev/tofu/state/` | every apply | **[static]** (dev: local backend **[verified]**) |
| Configuration | git (both repositories) + `versions.lock.yaml` + Zot | — | redeploy with `make deploy` |

Retention:
- PostgreSQL: `retention_policy` (stack 12 `postgres_backup`, default 7d).
- OpenBao snapshots: `openbao_snapshot_retention_days`; deleted versions in
  `platform-backup`: `noncurrent_version_retention_days` (S3 lifecycle on
  `platform-backup` only, applied by the snapshot job).
- Lakehouse buckets: versioned; noncurrent versions expire after
  `lakehouse_noncurrent_version_days` (stack 12, default 7 days) so that
  retention deletes become final. Within that window an accidental delete (e.g.
  `DROP TABLE` with purge, a faulty job) can be undone from the object versions
  (`rc undo` / copy the version back, then re-register the table metadata in
  Polaris); beyond it use Iceberg snapshots (within their expiry) and the
  off-site copy. Erasure is not delayed by the window: the erasure job deletes
  the versions of the objects it touched explicitly.

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

### Order matters: OpenBao first
Generated credentials (S3 keys, OIDC client secrets, Polaris root, service
passwords) live in OpenBao and are only *seeded* in the cluster: the
PushSecrets are create-only and every consumed Secret is read back from
OpenBao. Restore OpenBao (B) **before** applying stacks 12 and later, so that
the restored values are used and match restored databases and external
consumers. Exception: the CloudNativePG `<cluster>-app` credentials are
pushed with Replace (CNPG owns them and they must match the database that
exists); after a PITR into a new cluster, consumers take the new cluster's
`-app` Secret (scenario A).

### B. OpenBao data lost
1. If the pods are healthy but data is wrong: `CONFIRM=<env> make restore WHAT=openbao [KEY=openbao/raft-….snap] ENV=<env>` with a token holding sudo on `sys/storage/raft/snapshot`.
2. If the cluster is gone: deploy stack 10, `make openbao-init` **must not**
   initialise a new barrier for a restore — initialise, then force-restore the
   snapshot (`bao operator raft snapshot restore -force`) and unseal with the
   **old** unseal keys (key custody!). **[static]**
3. `make verify`; ESO and cert-manager reconnect automatically.

### C. Object storage lost
1. Recreate the buckets (`make deploy STACK=12-foundation-services`).
2. Copy back from the off-site target, per bucket, with `rc mirror
   dst/<target bucket>/<prefix>/<bucket> src/<bucket>` (the same pinned rc image,
   e.g. a Job derived from the `offsite-lake-copy` CronJob with source/target swapped;
   lake buckets come from `offsite.lake.bucket`, `platform-backup` from `offsite.bucket`).
   Lake data is as recent as the last off-site run (RPO = `offsite.lake.schedule`).
3. PostgreSQL/OpenBao restores from `platform-backup` (A, B); Polaris metadata
   (in polaris-db) and the Iceberg files must come from compatible points in
   time: restore polaris-db to the time of the off-site run.
4. Re-apply erasure requests executed after that point **[DPO/legal review]**. **[static]**

### D. Whole site lost
1. New hosts → `make cluster-up` (node bundle, air-gap) → Zot from the bundle (`make airgap-load`).
2. `make deploy` stacks 00–12 (OpenBao: scenario B with the old keys first). The OpenTofu state
   is in the off-site state bucket (`TOFU_STATE_S3_*`) and needs only the state passphrase; if the
   cluster itself is restored from an off-site etcd snapshot instead of rebuilt, `k3s server
   --cluster-reset --cluster-reset-restore-path=...` needs the old k3s server token.
3. Restore `platform-backup` from off-site (C), PostgreSQL clusters (A), data plane, `make verify`.
4. Re-apply erasure requests executed after the backup date (erasure log in the solution repo) **[DPO/legal review]**.

Prerequisites kept outside the site: off-site copy, OpenTofu state bucket,
unseal key shares, state passphrase, k3s server token
(`/var/lib/rancher/k3s/server/token`, needed to restore an etcd snapshot) and
agent token (`~/.boccob/<env>/k3s/agent-token`), registry CA, a checkout of both
repositories, the air-gap bundle.
