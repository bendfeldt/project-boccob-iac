# Boccob lakehouse: re-audit round 2

Date: 2026-11-18. Read-only. This audit follows AUDIT.md (round 1).
Solution HEAD: `93485f7`. IaC HEAD: `98a5602`. Both working trees are clean.
(Written incrementally; sections are added as they are completed.)

## 1. Checks run in round 2

| Check | Result |
|---|---|
| solution `make lint` | **PASS**: ruff, shellcheck, opa fmt/check, dbt parse, "classification ok: 125 columns in 10 models", exit 0 |
| solution `make test` | **PASS**: pytest 55 passed; OPA `PASS: 41/41`; Dagster definitions validate; exit 0 |
| IaC `make lint` | **PASS**: shellcheck, tofu fmt, all 10 stacks valid, lock-file consistency, exit 0 |
| Live dev cluster (`kubectl get nodes`) | **DOWN**: `connection to the server 127.0.0.1:6443 was refused`. The host has restarted. Per the rules I did not run `cluster-up`, so `make verify ENV=dev` could not run either. Every round-2 status below is **static**: code plus the workers' commit messages, which claim dev verification I cannot reproduce |

## 2. Round-1 findings re-checked

| ID | Round-1 finding | Status | Evidence (current code) | Remaining |
|---|---|---|---|---|
| C-1 | Noncurrent object versions keep erased/retention-deleted data; scan blind | **FIXED** (static) | IaC: lifecycle `noncurrentVersionExpiration` + `expiredObjectDeleteMarker` on the 4 lake buckets (`stacks/12-foundation-services/main.tf:48-59`, `modules/rustfs/main.tf:198-232`, variable `lakehouse_noncurrent_version_days` >= 1). Solution: `purge_noncurrent` after every erasure (`governance/erasure/executor.py:235`), in maintenance (`governance/maintenance/runner.py:55-80`) and in retention (purge user); `scan_storage` walks every version (`storage_scan.py:71-87`); harness buckets are versioned (`tests/integration/harness.sh:85-91`) | RustFS lifecycle execution not observed (cluster down); see N-3 (purge credential scope) and N-2 (off-site copy) |
| H-1 | Subject key in Trino query text -> WORM audit archive | **FIXED** | the queue is written by pyiceberg (`governance/erasure/queue.py`); every statement references `subject_query(request_id)` (`plan.py:89-97`); the audit digest is copied via INSERT...SELECT from a staging table (`executor.py` finally block); deregistration queuing uses INSERT...SELECT (`retention/runner.py:140-160`). Defence in depth: `audit_sink.py:23-36,59,84` redacts 64-hex and CPR-shaped literals (unit test `test_audit_sink.py`) | `AUDIT_FULL_EVENTS=true` redacts only `metadata.query` (failure messages and other fields are not redacted) - low |
| H-2 | Cluster-wide ESO stores, no namespace isolation | **FIXED** | ClusterSecretStores removed by default (`stacks/11-foundation-pki/variables.tf` `legacy_cluster_store_namespaces = []`); per-namespace SecretStores with SA-bound roles (`modules/namespace-baseline/main.tf:371-405`, `modules/openbao-config/main.tf:244-320`): read `kv/<ns>/*` + an explicit cross-read list, push only `kv/<ns>/*`, no delete; `deny_write` on `orchestration/pseudonym-pepper` | cross-read list widened by N-4 (database namespace can read lake data); within-namespace isolation remains namespace-level only (by design) |
| H-3 | Kyverno only audits in prod | **FIXED** (static) | `environments/{test,prod}/31-policy.tfvars` Enforce/Enforce/Fail; `scripts/deploy.sh:19-33` refuses prod (and `REQUIRE_POLICY_ENFORCE=1` envs) unless both modes are Enforce, with an explicit `POLICY_AUDIT_ACK` escape; built-in exceptions for Keycloak, RustFS init, log collector (`stacks/31-policy/main.tf:102-124`) | never run in Enforce on a cluster; the 13 failing dev PolicyReports from round 1 could not be re-checked (cluster down) - first prod deploy may reveal blocked pods. The grep-based guard accepts a commented-out/overridden value only if it is a leading `policy_mode = "Enforce"` line - acceptable |
| M-1 | Humans can write audit log / queue / keystore | **FIXED** | `governance/policies/lakehouse/config/data.yaml`: `protected: true` schemas `raw.governance`, `curated.keystore`, `curated.audit`, write only `lakehouse-service`; admin bypass removed for protected writes (`main.rego` `protected_write`); retention-floor override only for `lakehouse-service`; IaC gives the group only to svc-dagster as a static-only group (`stacks/21-query/variables.tf:64-68`, `group_sync` `STATIC_ONLY_GROUPS`); OPA tests 41/41 | platform-admin can no longer repair a protected table except through svc-dagster (break-glass procedure undocumented) - low |
| M-2 | Deregistered persons never deleted | **FIXED** | `meta.gdpr.deregistration {flag_column: is_deleted, since_column: source_updated_at, grace_days: 365}` (`clean/borgerportal/_models.yml:14-18`); retention queues them for erasure (`retention/runner.py:47-56,140-160`) | N-6: the erasure path also deletes `clean.payments`/`cases` that have their own 5-year retention (bookkeeping) |
| M-3 | TLS gaps (Trino inter-node, Dagster gRPC/HTTP) | **PARTIALLY FIXED** (mitigated, accepted residual) | WireGuard pod-network encryption for test/prod (`scripts/lib/k3s-config.sh:38-41`, `environments/{test,prod}/env.sh:17-20`); docs corrected to "TLS on every hop between namespaces; intra-namespace plaintext exceptions" (`docs/conventions.md:12-14`, `control-mapping.md:24`) | Trino still has no `internal-communication.https.required`; plaintext is visible on the node itself; dev has no WireGuard (single node, acceptable) |
| M-4 | Regenerated secrets overwrite restored OpenBao | **FIXED**; CNPG `-app` Replace **dispute accepted** | `modules/generated-secret/main.tf`: generator -> `<name>-seed` -> PushSecret `IfNotExists` -> KV -> ExternalSecret `<name>` (Periodic); OpenBao is the source of truth. CNPG `-app` keeps `updatePolicy: Replace` (`modules/postgres-cluster/main.tf:193`) | Dispute judged **valid**: CNPG owns and reconciles the app-role password, so the database cluster is the source of truth for its own credential; pushing it with Replace keeps OpenBao equal to what the restored database actually accepts. Residual (low): after a DB restore, consumers pick up the new value only after ESO refresh plus a pod restart |
| M-5 | Lake not copied off-site | **FIXED** with a new conflict | `offsite.buckets` defaults include the lake buckets with `propagate_deletes` (`stacks/32-backup/variables.tf:52-60`; `modules/s3-mirror/main.tf:38-40` `rc mirror --remove`) | N-2 (object lock / versioning on the target vs erasure), N-4 (backup credential now reads all lake data) |
| M-6 | case_types stale/empty snapshot | **FIXED** | `max_by(_load_id, cast(_load_id as double))` (`case_types.sql:13`); `snapshot: true` entities keep their latest load under index retention (`source.yml:28`, `retention/runner.py:74-82`) | - |
| M-7 | Facts stay on inferred key after adoption | **FIXED** | `keystore_rekey_adopted` re-selects fact rows whose key was adopted after `_transformed_at` (`keystore.sql:254-270`, `fact_payment.sql:39`); new test `scd2_version_valid_at_event` | static only (integration not run) |
| M-8 | Deep verify off outside dev; optimize threshold | **FIXED, over-corrected** | `ERASURE_VERIFY_STORAGE = "true"` for all environments (`stacks/22-orchestration/main.tf:117-118`) | N-1: a whole-lake scan of every object version per request is infeasible at prod scale |
| L1 | Out-of-band objects on dev (`test-code`, `policy-test`) | **UNVERIFIED** | cluster API down | re-check after cluster start |
| L2 | Absolute paths in OPA bundle | **FIXED** | commit `563023e` (relative module paths) | - |
| L3 | `process-forwarded` with direct 8443 clients | **FIXED** | `trino_client_namespaces` defaults to none; run pods use `https://trino.<base_domain>` through Traefik (`stacks/22-orchestration/main.tf:110-112`, `stacks/21-query/main.tf:34-37`) | - |
| L4 | Kyverno policies as a local Helm chart (second IaC language) | **DISPUTED - dispute accepted** | the chart is a thin, Tofu-driven template of Kyverno CRDs with no logic of its own; HCL `kubernetes_manifest` would need the CRDs at plan time (a bootstrap-order problem) | keep as a documented deviation (low) |
| L5 | Clear CPR in clean | **FIXED** | `cpr_number` removed from `clean/borgerportal/citizens.sql`; `docs/gdpr.md:84-87` | the removal itself is a schema change of an incremental model - see N-5 |
| L6 | No PDB for Dagster webserver / RustFS | **PARTIALLY FIXED** | PDBs for the Dagster webserver (`modules/dagster/main.tf:469`) and oauth2-proxy (`modules/oauth2-proxy/main.tf:197`) | RustFS (distributed, 4 nodes in prod) still has no PDB |
| L7 | Root token for Tofu | **PARTIALLY FIXED** (docs) | `scripts/lib/openbao.sh:53-64` documents a short-lived admin token in prod | dev still uses root; no scoped Tofu policy is shipped |
| L9 | dbt work tables with PII outside the erasure plan | **FIXED** | `drop_work_tables()` drops `__dbt_tmp`/`__stage`/`__dbt_backup` before erasing (`executor.py`) | - |

## 3. New defects (introduced by the fixes, or newly assessed)

### HIGH

**N-5. A solution release cannot change the schema of an incremental model without losing data: there is no upgrade path.** [high] Owner: solution (+ iac-ops for the release procedure)

What happens today:
- All five incremental models use `on_schema_change='fail'`: `clean/borgerportal/{citizens,cases,payments}.sql:6`, `consolidated/party/person.sql:6`, `curated/borgerservice/fact_payment.sql:6`.
- Any added, removed or retyped column therefore fails the model, and `dbt build` skips every child. `daily_refresh` keeps failing until somebody intervenes. This release's own L5 fix (dropping `cpr_number` from `clean.citizens`) is such a change.
- No migration mechanism exists: no full-refresh job, no release/migration script, no `on_schema_change` strategy. The only tool, `iac scripts/dev/reset-lakehouse-data.sh`, drops everything including the keystore and is dev-only by design.

Why `--full-refresh` (the obvious workaround) is destructive:
- clean is rebuilt from the raw index, which keeps only `index_days: 90` (native files 30 days).
- So clean loses the citizen change history, and cases/payments lose 5-year bookkeeping data older than 90 days.
- The rebuilt `person` and `dim_citizen` lose SCD2 versions, while the keystore keeps their version keys. Facts still point at keys that no longer have a dimension row (`keystore_usage` fails).
- A full refresh of `fact_payment` also drops the anonymised facts of erased subjects (their `clean.payments` rows are gone), which defeats `erasure: anonymise`.

Leftover `__dbt_tmp` objects are not the problem:
- dbt-trino drops pre-existing tmp, intermediate and backup relations before each incremental run (`.venv/.../dbt/include/trino/macros/materializations/incremental.sql:49-62`).
- The dimension stage is CREATE OR REPLACE.
- The erasure now drops work tables (`drop_work_tables`).
- Residual (low): `drop_work_tables` would also drop the tmp table of a dbt run started outside the Dagster pool (e.g. `make dbt-build`).

Fix:
- (a) Use `on_schema_change='append_new_columns'` (or `sync_all_columns` where safe) for additive changes.
- (b) For breaking changes, ship versioned migration SQL (`ALTER TABLE ... DROP/RENAME COLUMN` via a `dbt run-operation migrate_<release>`). Run it from a Dagster `migrate` job under the writer pool before the first `transform` of a release, and record applied migrations in a `curated.audit.schema_migrations` table.
- (c) Never full-refresh clean in test/prod: guard it in `scripts/dbt.sh` / the Dagster job, or make full refresh reuse `{{ this }}` as a source.
- (d) Document the procedure in `docs/adding-a-source.md` and the IaC release runbook.

### MEDIUM

**N-1. A whole-lake deep scan now runs for every erasure request in every environment.** [high] Owner: iac-data-plane (+ solution)
- `stacks/22-orchestration/main.tf:117-118` sets `ERASURE_VERIFY_STORAGE = "true"` for all environments.
- `execute_request` then reads and decodes **every object version of all four lake buckets** once per request (`executor.py:236-239`, `storage_scan.py:71-87`), which the module docstring itself calls "O(size of the lake) ... not for routine use".
- In prod this holds the `lakehouse_writer` pool for hours or days per nightly batch and blocks `daily_refresh`.
- Fix: default to `false` in test/prod and run the scan as a separate sampled or periodic verification job. Alternatively, scan only the table locations touched by the plan plus the raw files of the subject.

**N-2. Off-site lake copy conflicts with erasure.** [high] Owner: iac-ops
- `modules/s3-mirror` now mirrors the lake buckets with `--remove` so that deletions propagate.
- Its README still tells the off-site operator to enable versioning and **object lock (COMPLIANCE)** on the target bucket (`modules/s3-mirror/README.md:11-12`).
- On such a target a propagated delete only adds a delete marker. Erased raw files, Iceberg files and the transient erasure-queue Parquet stay retrievable or locked for the lock period, outside the reach of `purge_noncurrent`.
- Without versioning, on the other hand, the copy gives no protection against deletion or ransomware (see N-3).
- Fix:
  - Use separate target buckets: `platform-backup` gets lock and versioning; the lake prefix gets versioning **with** a short `NoncurrentVersionExpiration` and no object lock.
  - Document that erasure reaches the off-site copy only after one mirror run plus that expiry.
  - Add the off-site target to the erasure scope in `docs/gdpr.md`.

**N-3. Every run pod holds the credential that permanently destroys lake data, and the recovery nets are gone.** [high] Owner: iac-data-plane + iac-ops
- `PURGE_S3_*` (`s3:DeleteObjectVersion` on all four lake buckets, `modules/rustfs/main.tf:170-173`) sits in the shared `lakehouse-env` Secret. The K8sRunLauncher passes it to every run, including ingestion and dbt, not only to erasure, retention and maintenance.
- The recovery nets are gone:
  - maintenance and every erasure purge **all** noncurrent versions (`purge_noncurrent` with no age limit in the erasure path);
  - the lifecycle expires the rest after `lakehouse_noncurrent_version_days`;
  - the off-site copy propagates deletes.
- So an accidental `DROP TABLE` (purge), or a compromised run pod, is unrecoverable everywhere within hours.
- Fix:
  - Give the purge credential only to the erasure, retention and maintenance runs (separate code location or job-level `container_context` secrets).
  - Let the erasure purge only the object versions under the tables and files it touched.
  - Keep a delayed-deletion window (e.g. lifecycle 7 days, with the erasure purging explicitly).
  - Keep an off-site copy with its own version retention.

**N-4. The backup credential can now read the whole lake, including raw PII, from the database namespace.** [high] Owner: iac-foundation
- `default_s3_users["platform-backup"]` gained `read_only_buckets` on all four lake buckets (`stacks/12-foundation-services/main.tf:73-76`) for the off-site mirror.
- The same credential is read by the `database` namespace (CNPG barman: `stacks/11-foundation-pki/variables.tf` `database.reads`) and by `backup`.
- Every PostgreSQL pod's WAL archiver therefore carries read access to raw native files with clear CPR numbers.
- Fix: create a separate `platform-offsite-reader` user (read on the lake buckets, read-write nowhere), readable only by the `backup` namespace; keep `platform-backup` limited to its own bucket.

**N-6. Deregistration-driven erasure overrides per-table bookkeeping retention.** [medium] Owner: solution (policy decision)
- One year after deregistration the retention job queues a full erasure (`retention/runner.py:140-160`).
- That deletes `clean.payments` and `clean.cases` (`erasure: delete`) although they declare `retention_days: 1825` for bookkeeping. Only the anonymised `fact_payment` keeps the booking.
- Fix: honour per-table retention by turning those tables to `anonymise` for deregistration-driven requests, or let the deregistration rule skip tables whose `retention_days` has not expired. At minimum, have the controller/DPO confirm the behaviour in `docs/gdpr.md`.

**N-7. A late erasure failure loses the request, and one failure stops the rest of the queue.** [high] Owner: solution
- `execute_request` dequeues the request (and purges the queue history) **before** `purge_noncurrent` and the storage scan (`executor.py:233-239`).
- A PermissionError from the purge, or a storage hit, therefore marks the erasure `failed` while the subject key is already gone: it cannot be retried without the DPO resubmitting the identifier.
- `process_pending_requests` is a list comprehension, so the first exception aborts all remaining requests of the night. This contradicts its own docstring ("a failed request stays queued").
- Fix:
  - Keep the request (status column) until everything has succeeded, and exclude the queue table's own location from the scan.
  - Catch per request and continue, then raise a summary failure at the end.

### LOW
- **N-8** (solution) `erase_subject(dry_run=True)` (`make erase-dry-run`) writes a queue row through pyiceberg and purges queue history. A "dry run" mutates the lake and needs `lakehouse-service`/Polaris write credentials. Compute the counts from a temporary in-memory key path, or document it.
- **N-9** (solution) If `stage_digest` succeeds but the digest row is not visible to Trino (catalog cache, or the stage table dropped), the audit `INSERT ... SELECT ... where erasure_id = ?` inserts **zero rows** silently. Assert one inserted row and fail loudly otherwise.
- **N-10** (iac-data-plane) With `AUDIT_FULL_EVENTS=true`, only `metadata.query` is redacted. Failure messages, which can echo literals, are archived unredacted.
- **N-11** (solution/ops) Protected schemas have no admin bypass. A documented break-glass (svc-dagster session under four-eyes) is missing for keystore or audit-log repair.

## 4. Updated traceability (only the rows that changed since AUDIT.md; every other row keeps its round-1 status)

| # | Requirement / decision | Round 1 | Round 2 | Reason |
|---|---|---|---|---|
| R1 | Enterprise-grade, compliant | PARTIAL | **PARTIAL** | C-1, H-1, H-2, H-3 fixed; still open: N-5 (no upgrade path), N-1/N-2/N-3 (erasure scale, off-site, purge scope) |
| R12 | One IaC language | PARTIAL | **MET** (documented deviation) | the L4 dispute is accepted: the Kyverno CRDs do not exist at plan time |
| R18 | Clean layer | MET (with note) | **MET** | clear CPR removed from clean (L5) |
| R23 (new, derived from R1/R15: operable releases) | Solution releases can evolve table schemas without data loss | - | **NOT MET** | N-5 |
| D1 | GDPR/DPA/NIS2/ISO | PARTIAL | **PARTIAL** | N-2, N-3, N-4, N-6; MFA still off by default |
| D5 | OPA access | MET (M-1) | **MET** | protected schemas, lakehouse-service |
| D6 | Observability + audit | MET (H-1) | **MET** | redaction + no keys in SQL |
| D7 | Backup and DR | PARTIAL | **PARTIAL** | M-4 and M-5 fixed; N-2 (off-site vs erasure, lock), N-3 (no deletion safety net), N-4 (credential scope) |
| D8 | Supply chain incl. Kyverno | PARTIAL | **MET** (static) | Enforce in test/prod + deploy guard; never run in Enforce on a cluster |
| D10 | TLS everywhere | PARTIAL | **MET** (accepted residual) | WireGuard between nodes for test/prod; docs list the intra-namespace plaintext exceptions |
| D18d | Retention per layer | PARTIAL | **MET** | lifecycle on the lake buckets, deregistration rule, snapshot entities (N-6 is a policy-level note) |
| D18e | Scripted erasure | PARTIAL | **PARTIAL** | core gaps fixed (C-1, H-1, L9); open: N-1 (scale), N-2 (off-site residue), N-7 (lost or blocked requests) |
| D19 | Synthetic e2e demo | UNVERIFIED | **UNVERIFIED** | the dev cluster is down; the IaC commit `98a5602` claims an e2e run on dev that I could not reproduce |
| Lead default: secrets flow | PARTIAL | **MET** | per-namespace stores, OpenBao as source of truth, create-only seeds |

### Status counts after round 2 (47 rows: 23 requirements incl. new R23, 24 decisions)
- Requirements (23): **MET 20**, **PARTIAL 1** (R1), **UNVERIFIED 1** (R3 test/prod hosts), **NOT MET 1** (R23)
- Decisions (24): **MET 17**, **PARTIAL 3** (D1, D7, D18e), **UNVERIFIED 4** (D2, D12, D13, D19)
- **Total: MET 37, PARTIAL 4, UNVERIFIED 5, NOT MET 1**
- Lead defaults (10): MET 10

## 5. Round-1 finding statuses (summary)
- **Fixed (13):** C-1, H-1, H-2, H-3, M-1, M-2, M-6, M-7, L2, L3, L5, L9; M-8 is fixed but over-corrected (N-1)
- **Fixed with a new conflict (1):** M-5 (N-2, N-4)
- **Fixed, with the disputed part accepted (1):** M-4 (the CNPG `-app` Replace dispute is valid)
- **Partially fixed (3):** M-3 (accepted residual), L6 (RustFS PDB), L7 (dev root token)
- **Disputed, dispute accepted (1):** L4
- **Unverified (1):** L1 (cluster down)
- **Not fixed (0)**

New findings: 1 high (N-5), 6 medium (N-1, N-2, N-3, N-4, N-6, N-7), 4 low (N-8..N-11).
No new critical finding.
