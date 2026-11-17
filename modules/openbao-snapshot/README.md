# openbao-snapshot

CronJob that takes an OpenBao raft snapshot and stores it in S3 (RustFS).

- Container `snapshot` (bao CLI): logs in with the kubernetes auth method using a
  projected ServiceAccount token (audience `openbao`, 10 min), runs
  `bao operator raft snapshot save`, revokes its token.
- Container `upload` (rc): uploads `raft-<UTC timestamp>.snap` and its sha256 with
  SSE-S3, then imports the bucket lifecycle (retention) rules.
- The snapshot contains barrier-encrypted data: a restore needs the unseal keys.
- The caller creates the OpenBao policy (`read` on `sys/storage/raft/snapshot`) and a
  kubernetes auth role bound to the `service_account` output.
- Two regular containers (not init container + container): on k3s an init container
  could not pass the namespace's egress NetworkPolicies; the login also retries for
  ~60 s because NetworkPolicy allows for a new pod take a moment to apply.

```hcl
module "openbao_snapshot" {
  source       = "../../modules/openbao-snapshot"
  namespace    = module.ns_backup.name
  images       = { openbao = module.versions.images["openbao"].ref, rc = module.versions.images["rustfs-rc"].ref }
  openbao_role = "raft-snapshot"
  s3 = { endpoint = local.platform.s3_url, bucket = "platform-backup", credentials_secret = "platform-backup-s3" }
}
```
On demand: `kubectl -n backup create job snap-$(date +%s) --from=cronjob/openbao-snapshot` (or `make backup`).
