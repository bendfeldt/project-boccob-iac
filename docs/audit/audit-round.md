# Boccob lakehouse: requirements traceability and defect audit

Date: 2026-11-17. Auditor: independent, read-only.
Scope: `/home/user/project-boccob` (solution, HEAD `cf0bc66`, clean tree) and `/home/user/project-boccob-iac` (IaC, HEAD `b3e1694`, 1 uncommitted file `scripts/dev/e2e.sh` from the worker that is still running).
Branch in both: `claude/determined-lovelace-ugiz1b`.
Data-plane IaC (stacks 20/21/22, modules trino/opa/dagster/oauth2-proxy/polaris, `scripts/dev/e2e.sh`) was audited statically only and may still change.

Status legend: **MET** = implemented and evidenced. **PARTIAL** = implemented with a material gap. **NOT MET**. **UNVERIFIED** = code exists but I could not verify it (needs a deploy, HA hardware or the integration run, which I was not allowed to do).

---

## 1. Checks I ran (all read-only)

| Check | Result |
|---|---|
| solution `make lint` (ruff check + format, shellcheck, `opa fmt`/`opa check --strict`, `dbt --warn-error parse`, `lakehouse-pii check`) | **PASS**: "All checks passed", 55 files formatted, "classification ok: 126 columns in 10 models", exit 0 |
| solution `make test` (dbt parse, pytest, opa test, `dagster definitions validate`) | **PASS**: pytest 46 passed (6 deprecation warnings); OPA `PASS: 36/36`; "Validation successful for code location orchestration.definitions"; exit 0 |
| IaC `make lint` (shellcheck -x on all scripts/stack.env, `tofu fmt -check`, `tofu init -backend=false && tofu validate` for 10 stacks, lock-file consistency + digest check) | **PASS**: every stack 00..32 reports valid; "lint OK"; exit 0 |
| OPA bundle freshness (`dist/opa/bundle.tar.gz` compared with the sources) | rego files and `data.lakehouse.{classification,config}` are identical to the sources; revision `0.1.0-cf0bc66`. Rego modules sit under absolute build paths (L2) |
| Cross-repo artefact refs | `dist/image/image.ref` and `dist/opa/bundle.ref` match `environments/dev/22-orchestration.tfvars:2` and `environments/dev/21-query.tfvars:2` exactly |
| Git secret scan (`git grep` for private keys, AWS keys, literal passwords and secrets) | no hits in either repo (one false positive: key *names* in `modules/polaris/main.tf:356`) |
| `kubectl get` on the dev cluster (KUBECONFIG=/root/.boccob/dev/kubeconfig) | 1 node Ready (k3s v1.35.10+k3s1). All platform and data-plane pods Running; two Dagster run pods Completed. Leftovers: `orchestration/test-code` (CrashLoopBackOff, applied with kubectl) and namespace `policy-test` (L1). 13 failed PolicyReport results (Kyverno is in Audit mode) |
| Not run (forbidden or out of scope) | `make integration`, `make deploy/verify`, `scripts/dev/e2e.sh`, any S3 listing of the live buckets |

---

## 2. Traceability: the user's original requirements

| # | Requirement | Status | Evidence | Gap |
|---|---|---|---|---|
| R1 | Enterprise-grade, on-prem, open source, compliant for Danish/EU regulated and public sector | **PARTIAL** | `docs/compliance/control-mapping.md` (GDPR, databeskyttelsesloven, NIS2 art. 21, ISO 27001 Annex A); runbooks in `docs/compliance/runbooks/` | erasure leaves recoverable copies (C-1); pseudonyms of erased subjects end up in the WORM audit archive (H-1); secret isolation between namespaces is missing (H-2); Kyverno only audits in prod (H-3) |
| R2 | Everything containerised with Podman | **MET** | `scripts/build-image.sh:16` (`need podman`); `scripts/cluster/registry-up.sh`, `dev-up.sh` (Zot + k3s run as Podman containers) | - |
| R3 | Kubernetes = k3s | **MET** for dev, **UNVERIFIED** for test/prod | dev node `boccob-dev-server-0` Ready; `scripts/cluster/host-install.sh`, `hosts-up.sh`, `scripts/lib/k3s-config.sh:40-49` (secrets-encryption, protect-kernel-defaults, audit policy, admission config) | hosts mode was never executed |
| R4 | dlt ingestion | **MET** | `ingestion/framework/landing.py`, `indexing.py` (dlt filesystem destination; Iceberg index through Polaris) | - |
| R5 | RustFS object storage | **MET** | `modules/rustfs`; pod `storage/rustfs` Running | - |
| R6 | Iceberg tables | **MET** | Polaris catalogs per layer in `stacks/20-catalog/main.tf:30-37`; dbt-trino Iceberg models | - |
| R7 | Trino SQL | **MET** | `modules/trino`; coordinator 4/4 Running | - |
| R8 | dbt transformations | **MET** | `transform/` (dbt parse passes in lint and test) | - |
| R9 | Dagster orchestration | **MET** | `orchestration/`; `modules/dagster`; `dagster definitions validate` passes; webserver, daemon and code location Running | - |
| R10 | OpenBao secrets | **MET** (see H-2) | `modules/openbao`, `modules/openbao-config`, ESO stores in `stacks/11-foundation-pki/main.tf:135-170` | the ESO stores reach every KV path from every opted-in namespace (H-2) |
| R11 | Polaris catalogue | **MET** | `modules/polaris`, `stacks/20-catalog` (PostgreSQL metastore, one catalog per layer, least-privilege principals at `variables.tf:16-38`) | - |
| R12 | One IaC language (OpenTofu/HCL) | **PARTIAL** (low) | all stacks and modules are HCL | `modules/kyverno-policies/chart/` is a local Helm chart (Go-templated YAML) that Tofu wraps; k3s, audit and admission configs are raw YAML (unavoidable) |
| R13 | Solution separated from IaC | **MET** | the contract boundary is a digest-pinned image and bundle consumed as variables (`stacks/22-orchestration/variables.tf:3`, `stacks/21-query` `opa_bundle_ref`); no cross-repo file references found | - |
| R14 | All deployment via scripts | **MET** (with L1) | `Makefile` targets wrap `scripts/*` in both repos; `scripts/deploy.sh` | the dev cluster holds out-of-band kubectl objects (L1) |
| R15 | Modular, reusable, scalable | **MET** | 33 reusable modules; sizing and replica counts are variables (`ha`, `*_replicas`, `trino_worker_autoscaling`) | - |
| R16 | Layers raw -> clean -> consolidated -> curated | **MET** | `transform/dbt_project.yml` (catalog per layer); `docs/data-layers.md` | - |
| R17 | Raw = landing area, native format, no structural assumptions, source aligned | **MET** | `landing.py:1-12` (byte-for-byte copy, manifest commit marker); `indexing.py:1-20` (payload as text, schema-on-read) | - |
| R18 | Clean = cleaned, denormalised, structured, Iceberg, source aligned | **MET** | `models/clean/borgerportal/*.sql` (parsing, typing, dedupe, address denormalised) | clean keeps the clear `cpr_number` column, masked (L5) |
| R19 | Consolidated = optional business entities | **MET** | `models/consolidated/party/person.sql` | - |
| R20 | Curated = dimensional models + data products | **MET** | `dim_citizen`, `dim_case_type`, `dim_date`, `fact_payment`, `dp_payment_summary` (versioned, contract enforced, small-cell row filter) | - |
| R21 | Keystore reuses previously created surrogate keys | **MET** (static + unit tests; integration tests `test_02`/`test_03`/`test_09` exist but I did not run them) | `macros/keystore/keystore.sql` `keystore_allocate` (allocates only missing keys, optimistic and verified); `materializations/dimension.sql` step 4 | adoption edge case (M-7) |
| R22 | Keystore records key creation and last use in a fact | **MET** | `key_created_at`/`key_created_by`, `key_last_used_in_fact_at`/`key_last_used_by` (`keystore.sql` `keystore_ensure`, `keystore_mark_used` post-hook in `fact_payment.sql`) | - |

## 3. Traceability: user decisions in the contract

| # | Decision | Status | Evidence | Gap |
|---|---|---|---|---|
| D1 | GDPR + databeskyttelsesloven (CPR), NIS2, ISO 27001/27002 | **PARTIAL** | control mapping and runbooks; HMAC pseudonymisation of the CPR (`ingestion/framework/pseudonym.py`) | C-1, H-1, H-2, H-3, M-2; MFA is not enforced in Keycloak (`control-mapping.md:52,90`, documented as residual) |
| D2 | k3s everywhere; dev = k3s in Podman; test/prod on hosts, CIS-hardened, air-gap install | dev **MET**, test/prod **UNVERIFIED** | `scripts/cluster/dev-up.sh`; `k3s-config.sh`; `scripts/airgap/node-bundle.sh` | hosts path never run |
| D3 | Full stack dlt/RustFS/Iceberg/Trino/dbt/Dagster/OpenBao/Polaris | **MET** | see R4-R11 | - |
| D4 | Keycloak OIDC SSO | **MET** | `modules/keycloak`; Trino OAUTH2 (`modules/trino/main.tf:285-297`); oauth2-proxy in front of Dagster; Grafana and OpenBao OIDC clients | MFA off by default |
| D5 | OPA table/column/row access, PII masks, policies as code | **MET** (with M-1) | `governance/policies/trino/{main,masking}.rego`; generated `classification/data.json`; 36/36 policy tests | human data engineers can write `curated.audit` and `curated.keystore` (M-1) |
| D6 | Observability + audit (Prometheus, Grafana, Loki, OTel; central audit from Trino/Polaris/OpenBao/K8s) | **MET** (Grafana not deployed in dev: `MIRROR_EXCLUDE_GROUPS`) | `stacks/30-observability/main.tf:1-7,189-192` (Loki `audit` tenant); WORM `platform-audit` archive; Trino `audit_sink.py`; OPA decision logs; k3s audit policy | the audit trail stores full query text, including subject keys (H-1) |
| D7 | Backup and DR (Postgres, OpenBao raft snapshots, object storage versioning/replication) | **PARTIAL** | barman to `s3://platform-backup` (stacks 20/22 `postgres_backup`); `modules/openbao-snapshot`; `make restore-test` | lake buckets are not replicated off-site (M-5); regenerated secrets overwrite restored OpenBao values (M-4); versioning has no lifecycle rule (C-1) |
| D8 | Supply chain: Trivy, SBOM, cosign, Kyverno | **PARTIAL** | `scripts/supply-chain/*`; `modules/kyverno-policies` (ImageValidatingPolicy with the OpenBao transit key) | every environment defaults to `Audit`; no test/prod override (H-3) |
| D9 | Zot registry for air-gap; images and charts pinned by digest | **MET** | `scripts/airgap/mirror.sh`; `versions.lock.yaml` (lint checks that every image has a digest); `modules/versions/main.tf:11,26` (charts from `oci://<zot>/charts`) | Zot uses a bootstrap CA rather than OpenBao PKI (chicken-and-egg, acceptable) |
| D10 | cert-manager from OpenBao PKI; TLS everywhere; internal CA | **PARTIAL** | `stacks/11-foundation-pki`; `modules/tls-certificate`; PG `sslmode=verify-full` | Trino coordinator-worker on plain HTTP 8080; Dagster gRPC 4000 and webserver 80 in plaintext; the docs still claim "TLS everywhere" (M-3) |
| D11 | OpenTofu only; bash + Makefile; no CI | **MET** | no CI files in either repo; Makefiles wrap scripts | - |
| D12 | dev/test/prod from one module set, air-gapped | **MET** (static) / **UNVERIFIED** (test/prod) | `environments/{dev,test,prod}`; prod `env.sh` (PGP-encrypted unseal shares, `STATE_ENCRYPTION=pbkdf2-env`) | - |
| D13 | HA test/prod (CNPG replicas, 3-node OpenBao raft, distributed RustFS, Trino coordinator + autoscaled workers, multi-replica Polaris/Keycloak), all sizing via variables | **UNVERIFIED** (variables present) | prod `12-foundation-services.tfvars` (3 PG, 4x4 RustFS, 2 Keycloak), `10-foundation-secrets.tfvars` (3 OpenBao), `21-query.tfvars` (2-6 workers, HPA/KEDA); `ha ? 2 : 1` for Polaris, OPA and the Dagster webserver | no HA deploy was run; the Dagster webserver has no PDB (L6) |
| D14 | Repositories and branch; no model names in commits | **MET** | both repos are on `claude/determined-lovelace-ugiz1b` | - |
| D15 | Layer semantics (raw/clean/consolidated/curated) | **MET** | R16-R20 | - |
| D16 | Keystore reuses keys and records created/last used | **MET** | R21-R22 | - |
| D17 | SCD2 by default, SCD1 per dimension, stable sequential integer keys | **MET** | `dbt_project.yml` vars `scd_default_type: 2`, `keystore_key_type: bigint`; `dimension.sql` handles `scd_type` 1 and 2; tests `scd2_no_overlap`, `scd2_contiguous_one_current`, `keystore_integrity`, `keystore_stable_since_baseline` | - |
| D18a | PII classification (dbt meta) | **MET** | `lakehouse-pii check` passes (126 columns) | - |
| D18b | OPA column masks by role | **MET** | `masking.rego`; `pii_levels_masked: [direct, sensitive]` | - |
| D18c | Pseudonymised keys from clean onward | **MET** | `subject_key()` macro reads the HMAC computed at indexing; the pepper never reaches SQL | clean keeps the clear CPR as a masked attribute (L5) |
| D18d | Retention policy per layer | **PARTIAL** | `governance/retention.yml`; `retention/runner.py`; meta `retention_days` | deregistered master data is never deleted (M-2); deleted objects persist as noncurrent versions (C-1) |
| D18e | Scripted right to erasure (Iceberg deletes + snapshot expiry + raw file removal) | **PARTIAL** | `governance/erasure/{plan,executor}.py`; request queue; Dagster job `erasure`; audit row with a keyed digest | C-1 (versioned buckets), H-1 (key in query logs), L9 (orphaned stage tables) |
| D19 | Synthetic demo end-to-end through all four layers including the keystore | **UNVERIFIED** by me | `ingestion/sources/borgerportal/generator.py`; `tests/integration/test_e2e.py` (9 tests); two Completed Dagster run pods on dev | the integration run and the IaC e2e were not run (forbidden / still in flux) |
| D20 | Modular everywhere | **MET** | - | - |

### Lead defaults

| Default | Status | Evidence / gap |
|---|---|---|
| Buckets `lakehouse-{raw,clean,consolidated,curated}`, `platform-backup`, `platform-logs` | **MET** | `stacks/12-foundation-services/main.tf:48-57` (plus `platform-audit`) |
| One Polaris catalog per layer; Trino catalogs with the same names | **MET** | `stacks/20-catalog/main.tf:30-37`; `stacks/21-query/main.tf:76` |
| Raw native-file layout + schema-on-read index table | **MET** | `landing.py:4-8`; `indexing.py:1-20` |
| Dagster orchestrates dlt + dbt + maintenance, retention, erasure | **MET** | `orchestration/jobs.py`, `orchestration/assets/*` |
| Kubernetes namespaces as specified | **MET** | `stacks/_shared/common.tf`; live namespaces match |
| Secret flow OpenBao -> ESO -> Secret; Kubernetes auth; PKI -> ClusterIssuer; no secrets in git, tfvars or outputs; state encrypted | **PARTIAL** | in-cluster generation (`modules/generated-secret`), pepper created once by a Job (`modules/dagster/main.tf:68-197`), outputs carry KV paths only, `scripts/tofu.sh:53-85` pbkdf2 state encryption. Gaps: H-2 (store scope); generated secrets flow Secret -> OpenBao (`updatePolicy: Replace`), the reverse of the contract (M-4); root token used for applies (L7) |
| Ingress `<svc>.<env>.lakehouse.internal` | **MET** | `ingress-host` modules with `base_domain` |
| Interface = image + bundle by digest via variables | **MET** | see section 1 |
| PSS restricted, default-deny NetworkPolicy, non-root, read-only rootfs, requests/limits, PDB + topology spread in HA | **MET** (minor gaps) | `modules/namespace-baseline` (restricted by default; only `30-observability` is privileged, with a stated reason). Dagster webserver and RustFS have no PDB (L6) |

### Status counts (each row counted once, by its worst status)
- User requirements (22 rows): **MET 19**, **PARTIAL 2** (R1, R12), **UNVERIFIED 1** (R3: met in dev, test/prod hosts never run), **NOT MET 0**
- Contract decisions (24 rows, with D18 split into a-e): **MET 14**, **PARTIAL 6** (D1, D7, D8, D10, D18d, D18e), **UNVERIFIED 4** (D2, D12, D13, D19), **NOT MET 0**
- **Total (46 rows): MET 33, PARTIAL 8, UNVERIFIED 5, NOT MET 0**
- Lead defaults (10 rows): MET 9, PARTIAL 1 (secrets flow)

---

## 4. Findings (verified against code; confidence in brackets)

### CRITICAL

**C-1. Erased and retention-deleted data stays recoverable as noncurrent S3 object versions in every lakehouse bucket, and erasure verification cannot see it.** [high]
Owner: iac-foundation (bucket config) + solution (erasure/verification) + iac-ops (lifecycle, docs)
- `modules/rustfs/variables.tf:88` sets `versioning = optional(bool, true)`. `stacks/12-foundation-services/main.tf:48-57` creates `lakehouse-raw/clean/consolidated/curated` with `{}`, so versioning is on (`scripts/verify.sh:193` even checks it).
- Only `platform-backup` gets a noncurrent-version lifecycle (`stacks/32-backup/main.tf:26-37,117,121`). No rule exists for the lakehouse buckets.
- Erasure step 8 (`governance/iceberg.py:103-120`: `purge_history`, then `expire_snapshots`/`remove_orphan_files` 0s), Polaris drop-with-purge and the retention deletes all go through Trino or Polaris with plain DeleteObject. On a versioned bucket each of these only adds a delete marker: the Parquet data files, delete files and Avro manifests that hold the subject's rows (and the CPR/name min-max bounds) stay retrievable through `ListObjectVersions`/`GetObject?versionId=` indefinitely. The same applies to raw Iceberg index files under `lakehouse-raw/iceberg/` and to raw native files deleted by retention. Only the explicit native-file erasure (`lakehouse/objectstore.py:17-42`) removes versions.
- `governance/erasure/storage_scan.py:70-77` walks `fs.find(bucket)` (current versions only), so `ERASURE_VERIFY_STORAGE=true` reports success while the data is still there.
- The integration harness creates unversioned buckets (`tests/integration/harness.sh:80-89`), so `test_06_erasure_removes_the_subject_everywhere` cannot catch this.
- The docs say the opposite of what the code does: `docs/gdpr.md:142-146` ("every older data file ... removed"), `iac docs/compliance/control-mapping.md:20` (object versions "until they expire (`noncurrent_version_retention_days`)", but that lifecycle covers `platform-backup` only), and `disaster-recovery.md` "Retention" paragraph.
- Fix:
  - (a) iac-foundation: either set `versioning = false` for `lakehouse-clean/consolidated/curated` (Iceberg snapshots already give the time-travel and recovery window), or apply a lifecycle to all four lakehouse buckets with `NoncurrentVersionExpiration` (1-3 days) and `ExpiredObjectDeleteMarker`. Do this through the rustfs bucket config, not only stack 32.
  - (b) solution: after `purge_history`, call `ListObjectVersions` on the touched table locations and delete the noncurrent versions. This needs delete rights, so it belongs to an erasure S3 user or to Polaris. Make `scan_storage` iterate object versions.
  - (c) Enable versioning in the harness so `test_06` exercises the path.
  - (d) Correct the three docs.

### HIGH

**H-1. The pseudonymised key of every erased subject is written in clear to the Trino audit trail and archived WORM (object lock), so it can never be erased.** [high]
Owner: solution (erasure SQL) + iac-data-plane (audit sink) + iac-ops (archive)
- `governance/erasure/plan.py:85` builds `lit = f"'{key}'"` and embeds it in every statement (`:97-104,117,173,176,186,195`). `executor.py` adds `delete from ... where business_key = '{key}'` for baselines, `submit_request` and `dequeue`. With trino-python-client the parameters (`?`) are also inlined into the `EXECUTE ... USING` text.
- `modules/trino/files/audit_sink.py:37` copies `metadata.query` into every audit record. `stacks/30-observability/main.tf:189-192` routes the `audit-log` container to the Loki `audit` tenant, which is exported daily to `platform-audit` under object lock COMPLIANCE (`stacks/12-foundation-services/main.tf:56`).
- This defeats the design. `executor.py` `audit_digest()` exists exactly so that the erasure log "identifies nobody". The key is HMAC(pepper, CPR): anyone holding the pepper and the audit archive can confirm that a given CPR number was erased. `docs/platform-contract.md:167` claims query logs "can be shipped as they are". Ad-hoc queries of pii-readers that filter on literal CPR numbers end up in the same WORM archive (same mechanism).
- Fix:
  - solution: never put the key in SQL text. Write the queue row through pyiceberg (not Trino), have the plan reference `(select subject_key from curated.audit.erasure_requests where request_id = '<uuid>')`, and keep a session-only copy for verification after dequeue, or verify by `erasure_id`.
  - iac-data-plane: in `audit_sink.py`, redact 64-hex literals and CPR-shaped literals (`\d{6}-?\d{4}`) in `query`, or drop `query` for `source == lakehouse-erasure`.
  - Correct `platform-contract.md:167`.

**H-2. One cluster-wide ESO read store (`kv/*`) and one write store (`kv/*`) serve every opted-in namespace: there is no secret isolation between namespaces, and the pepper can be overwritten.** [high on the mechanism; exploitability depends on who may create ESO resources]
Owner: iac-foundation
- `stacks/11-foundation-pki/main.tf:135-170` creates two ClusterSecretStores whose only condition is the label `boccob.io/secrets-access=true`. The label is set in database, storage, identity, catalog, query, orchestration, observability and backup.
- `modules/openbao-config/main.tf:127-149` grants the read store `read` on `kv/data/*` and the push store `create,update` on `kv/data/*` plus `delete` on metadata.
- Consequence: any ExternalSecret in, for example, `observability` or `backup` can read `orchestration/pseudonym-pepper`, the Polaris root credentials, Keycloak admin and every S3 key. Any PushSecret can replace them. The pepper Job's create-only policy (`modules/dagster/main.tf:78-89`) is meaningless while the push store can update the same path. The same holds for the Kubernetes Secret source of a PushSecret with `updatePolicy: Replace` (`modules/generated-secret/main.tf:86-89`).
- Fix: use namespaced SecretStores (or ClusterSecretStores whose condition selects a single namespace), each with its own OpenBao Kubernetes-auth role bound to that namespace and a policy limited to `kv/data/<ns>/*` plus explicit cross-namespace reads (orchestration: `storage/s3-users/lakehouse-orchestration`, `catalog/polaris/principals/ingest`, `query/trino/service-accounts/svc-dagster`). Deny writes to `orchestration/pseudonym-pepper` for every identity except the pepper Job. Optionally add a Kyverno rule that rejects `remoteRef.key` outside the namespace prefix.

**H-3. Admission policies (signatures, digest pinning, non-root, read-only rootfs) only audit in test and prod.** [high]
Owner: iac-ops
- `stacks/31-policy/variables.tf:35-39`: `policy_mode` defaults to `"Audit"`. `signature_mode` (`:65-69`) defaults to `policy_mode`. No `environments/{test,prod}/31-policy.tfvars` exists. The enforce label `boccob.io/policy-enforce` is not set on any platform namespace (on dev it exists only on the ad-hoc `policy-test` namespace).
- So unsigned or unpinned images and root pods are admitted in prod. The cosign signing chain (`scripts/supply-chain/sign.sh`, transit key) is never a gate. Dev already shows 13 failing PolicyReport results.
- Fix: add `environments/{test,prod}/31-policy.tfvars` with `policy_mode = "Enforce"`, `signature_mode = "Enforce"` and `policy_failure_policy = "Fail"`. Make `scripts/deploy.sh` refuse `ENV=prod` while the mode is `Audit`, or set the enforce label from `namespace-baseline` when `ha = true`.

### MEDIUM

**M-1. Human `data-engineer` users can write the erasure audit log, the erasure queue and the keystore.** [high] Owner: solution (OPA config)
`governance/policies/lakehouse/config/data.yaml:46-48` overrides only `read` for `curated.audit`. `main.rego:41-45` `allowed_groups` falls back to the catalog's `write: [data-engineer]`, and the same applies to `curated.keystore`. Any engineer can therefore:
- `DELETE FROM curated.audit.erasure_log` (accountability evidence, GDPR art. 5(2));
- `INSERT` arbitrary subjects into `erasure_requests`, which the nightly job erases with no DPO step;
- `UPDATE` keystore rows, which breaks key stability.

Engineers can also run `expire_snapshots`/`remove_orphan_files` with a 0s retention because `retention_override` is allowed for writers (`main.rego` SetCatalogSessionProperty).

Fix: set `write: []` on the `audit` and `keystore` schemas. Grant them to a dedicated service group (e.g. `lakehouse-service`, carried only by `svc-dagster` through the IaC `trino_service_accounts` static groups and the OPA `principals` overlay). Restrict the retention override to that group.

**M-2. Master data of deregistered persons is never deleted.** [high] Owner: solution
`governance/retention.yml:3` says master data is "kept until erased or deregistered". No code acts on `is_deleted`/`is_deregistered` (grep across `governance/`, `transform/`, `ingestion/`). `clean.citizens`, `consolidated.party.person` and `dim_citizen` keep deregistered people forever (storage limitation, art. 5(1)(e)).
Fix: add a retention rule keyed on the deregistration timestamp (e.g. `retention_days` with a `retention_condition: is_deleted`), or have the retention job enqueue erasure requests for persons deregistered more than N days ago.

**M-3. "TLS everywhere" is not true for the data plane.** [high] Owner: iac-data-plane (+ docs)
- Trino coordinator to worker traffic uses plain HTTP 8080 with a shared secret (`modules/trino/README.md:10`; `modules/trino/main.tf:318-320` has no `internal-communication.https.required`). With `trino_workers=2` in test/prod, query results containing PII cross nodes unencrypted.
- The Dagster daemon/webserver talk to the code server over gRPC 4000 in plaintext, and oauth2-proxy reaches the webserver over HTTP 80 (`stacks/22-orchestration/main.tf:44-51`).
- `iac docs/conventions.md:12` and `control-mapping.md:24,50` claim TLS everywhere.

Fix: enable `internal-communication.https.required=true` with the cert-manager keystore on workers. Document the Dagster plaintext hops as a residual risk confined by NetworkPolicy (or add a mesh/sidecar). Correct the docs.

**M-4. DR: in-cluster generated secrets overwrite restored OpenBao values.** [medium] Owner: iac-foundation / iac-ops
`modules/generated-secret/main.tf:36-41,86-89` generates once per Kubernetes Secret (`refreshPolicy: CreatedOnce`) and pushes it with `updatePolicy: Replace`. `modules/postgres-cluster/main.tf:189` does the same for the CNPG `-app` secret.

On a rebuilt cluster (DR scenarios B and D, `docs/compliance/runbooks/disaster-recovery.md`), the restored OpenBao snapshot is overwritten by freshly generated S3 keys, service-account passwords, the Polaris root secret and DB app passwords. Restored PostgreSQL databases and any external consumer then hold different credentials. The pepper is safe because the Job uses CAS 0.

Fix: source generated secrets from OpenBao first (ExternalSecret `extract` from KV, with the generator only as fallback), or use PushSecret `updatePolicy: IfNotExists`. Add the step and its order to the DR runbook.

**M-5. Lake data has no off-site or replicated copy by default.** [high] Owner: iac-ops
`modules/s3-mirror` and `stacks/32-backup` copy only `platform-backup`. The DR runbook table admits it ("lake data itself is not copied off-site by default"), yet scenario C promises "restore from the off-site target". The raw native files are the only system-of-record copy for re-processing, and the contract asks for object storage replication.
Fix: add an `offsite.buckets` list (default: the four lakehouse buckets, at least `lakehouse-raw`) or a RustFS site-replication variable. Align scenario C.

**M-6. `clean.case_types` can select a stale or empty reference snapshot.** [medium] Owner: solution
- `models/clean/borgerportal/case_types.sql:10` uses `max_by(_load_id, _loaded_at)`. `ingestion/framework/indexing.py:140` stamps one `_loaded_at` for all loads indexed in one run, so a backfill or catch-up of several loads gives ties and an arbitrary pick, possibly an older snapshot.
- The model is a full rebuild from the raw index, whose rows expire after `index_days: 90` (`retention.yml`). If case types stop being delivered for 90 days, the table empties and `dim_case_type` keeps only placeholder members.
- Fix: order by `cast(_load_id as double)` (load ids are numeric strings), or by `max(_raw_file)`/the manifest. Make reference entities incremental, or exempt them from index retention.

**M-7. Facts keyed to an inferred member keep the earliest-version key after adoption.** [medium] Owner: solution
`keystore.sql` `keystore_allocate` adopts the inferred key onto `min(version_key)`. `fact_payment` is incremental (`p._loaded_at > max(...)`) and never re-keys. A payment dated after a later SCD2 version therefore stays on the first version's key, even though the dimension now has a correct version for that date.
Fix: after adoption, re-key affected fact rows (a merge on `citizen_key` where the key was inferred), or document the limitation in `docs/keystore.md`.

**M-8. Deep erasure verification is off outside dev, and optimize may leave rows in large files.** [low-medium; the second part has low confidence] Owner: iac-data-plane / solution
- `ERASURE_VERIFY_STORAGE` is set only in `environments/dev/22-orchestration.tfvars:4`.
- `purge_history` calls `optimize` without a threshold (Trino default 100MB). Whether Trino always rewrites larger files that carry deletes was not verified here.
- Fix: set `ERASURE_VERIFY_STORAGE=true` in test/prod, or document why not. Pass an explicit large `file_size_threshold` in `purge_history`, and verify with the integration test on a file above 100MB.

### LOW

- **L1** (iac-ops / dev hygiene) The dev cluster holds out-of-band objects: Deployment `orchestration/test-code` (kubectl `last-applied`, CrashLoopBackOff, same solution image) and namespace `policy-test`. Remove them once the data-plane worker finishes. They contradict "deployment only via scripts".
- **L2** (solution) `scripts/build-opa-bundle.sh:12` passes an absolute path to `opa build`, so the bundle stores modules as `/home/user/project-boccob/governance/policies/...`. This leaks a host path and makes the bundle non-reproducible. Fix: `cd governance/policies && opa build --bundle .`.
- **L3** (iac-data-plane) `modules/trino/main.tf:298` sets `http-server.process-forwarded=true`, while pods in orchestration and observability reach 8443 directly (`stacks/21-query/main.tf:35`). They can forge `X-Forwarded-For`, which then appears as `remote_address` in the audit trail. Fix: accept forwarded headers only from Traefik, or drop direct client access.
- **L4** (iac-ops) `modules/kyverno-policies/chart` is Helm templating, a second IaC language (R12). Consider `kubernetes_manifest` resources in HCL.
- **L5** (solution) `clean.citizens.cpr_number` keeps the clear CPR (masked for non-pii-readers). Data minimisation suggests dropping it after pseudonymisation; the raw index already has it.
- **L6** (iac-data-plane/foundation) The Dagster webserver (2 replicas with `ha`) and RustFS have no PodDisruptionBudget (grep across `modules/*/main.tf`).
- **L7** (iac-foundation) `scripts/lib/openbao.sh:53-64` uses the root token, or an operator-exported token, for every Tofu apply. ISO A.8.2 calls for a scoped Tofu policy/token and revoking root after init.
- **L9** (solution) A failed dimension or incremental run leaves `<model>__stage` / `__dbt_tmp` tables with PII in curated or clean. They are not in the erasure plan (masked for analysts as unclassified). Fix: have the erasure (or maintenance) job drop stale `__stage`/`__dbt_tmp` tables first.

### Cross-repo contract check (`project-boccob/docs/platform-contract.md` vs IaC)
All of these match `stacks/22-orchestration/main.tf:84-125` and `modules/dagster/main.tf`:
- env vars (`S3_*`, `POLARIS_*`, catalogs, `TRINO_*` 8443/https, `DBT_TARGET=password`, `SCHEDULE_*`);
- the secret set incl. `PSEUDONYM_PEPPER`;
- `/tmp` emptyDir, uid 10001, port 4000, module `orchestration.definitions`;
- `includeConfigInLaunchedRuns`, pool `lakehouse_writer=1` (`modules/dagster/variables.tf:83-87` + pools Job);
- egress to Trino, Polaris, RustFS and PG;
- svc-dagster in `data-engineer` + `pii-reader` (`stacks/21-query/variables.tf:57-66`);
- Polaris catalogs with drop-with-purge and least-privilege principals;
- the S3 user `lakehouse-orchestration` (rw raw, ro other layers) defined in all three envs' `12-foundation-services.tfvars`.

Deviations:
- OPA runs over HTTPS (`modules/opa/variables.tf:59-63`), while the contract states http. The IaC is stricter, so this is fine; update the contract text.
- Groups for service accounts come from a static group file instead of the OPA `principals` overlay. This is equivalent.
- The only false contract claim is `platform-contract.md:167` (H-1).

### In flux (not judged final)
`scripts/dev/e2e.sh` (uncommitted change) and stacks 20/21/22 may still change. My data-plane findings (H-1 sink side, M-3, M-8, L3, L6) are static and should be re-checked after that worker lands.
