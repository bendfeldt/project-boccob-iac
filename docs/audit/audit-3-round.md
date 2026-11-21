# Boccob lakehouse: re-audit round 3 (final)

Date: 2026-11-18. Read-only. This audit follows AUDIT.md and AUDIT-2.md.
(Written incrementally; sections are added as they are completed.)

Solution HEAD: `3b29697`. IaC HEAD: `b3e7fe1`. Both working trees are clean. The dev cluster is up (node Ready, 47h).

## 1. Checks run

| Check | Result |
|---|---|
| solution `make lint` | **PASS**: "classification ok: 127 columns in 10 models", exit 0 |
| solution `make test` | **PASS**: pytest 80 passed, OPA 41/41, Dagster definitions validate, exit 0 |
| IaC `make lint` | **PASS**: all stacks valid (now 11, with `13-identity`), lock file ok, exit 0 |
| IaC `make verify ENV=dev` (with `VERIFY_RESTORE_TEST=0`; I skipped the restore test because it creates a scratch cluster) | **99 passed, 1 failed**. The failure is "no pod in a failed/pending state". The causes are leftovers: 6 platform pods **Evicted** for node ephemeral-storage pressure (the sandbox disk is 91% full), plus failed `openbao-snapshot`/`offsite-copy`/`audit-archive` CronJob pods from the restart window. The newest backups pass ("OpenBao snapshot < 2h", off-site lake copy ok). Environmental, not a code defect (see R3-6). Passing checks include: tofu state encrypted, namespaced-store isolation (observability cannot read the pepper; database cannot read the lake reader credential), lifecycle on all 4 lake buckets, off-site target guard, the 3 purge-guard admission dry runs, and Kyverno blocking a non-compliant pod in an enforced namespace |
| `kubectl get jobs -n orchestration` | completed Dagster runs: `daily_refresh` 6, `erasure` 7, `migrate` 3, 0 failed |
| L1 leftovers | `orchestration/test-code` and namespace `policy-test` are **gone** |

## 2. Status of AUDIT-2 findings and carried items

| ID | Status | Evidence | Remaining |
|---|---|---|---|
| N-1 deep scan per request | **FIXED** | `erasure_verify_storage` = `scoped` in test/prod, `full` in dev (`stacks/22-orchestration/variables.tf:14-20`, env tfvars); the solution scans only the touched locations plus the subject's raw files (`executor.py` around 337-345) | - |
| N-2 off-site copy vs erasure | **FIXED** | separate lake target; every run refuses a target with object lock, or versioned without a short noncurrent expiry (`modules/s3-mirror/main.tf:44-60`); verify "off-site lake copy: target bucket passes the erasure check" PASS | - |
| N-3 purge credential in every run | **FIXED, but bypassable by Dagster UI users** | `lakehouse-purge-env` is attached only by the purge jobs' `dagster-k8s/config` tag; ValidatingAdmissionPolicies require `dagster/job` in the purge-job list and creator = the launcher SA for Jobs / the job-controller for Pods (`modules/dagster/main.tf:302-385`); all 3 verify dry runs PASS; 7-day grace window kept (maintenance purges only older than `max(grace, orphan retention)`, `governance/maintenance/runner.py:68-90`; retention does plain deletes, `retention/runner.py:211-215`) | **R3-1**: a Dagster UI user can forge both the label and the command through run tags |
| N-4 backup credential reads the lake | **FIXED** | `platform-offsite-reader` user, readable only from `backup`; `platform-backup` back to its own bucket; verify PASS ("S3 user platform-backup ... has no grant on the lake buckets", "database cannot read ... platform-offsite-reader") | - |
| N-5 no schema upgrade path | **FIXED** | `on_schema_change='append_new_columns'` on all 5 incremental models; versioned migrations `transform/migrations/V0001..V0002` run by `governance/migrations/runner.py` (checksum and unknown-version checks, idempotent `IF EXISTS` statements, `@purge-history` with full rewrite, forbidden key/CPR literals, record in protected `curated.audit.schema_migrations`); `migrate` precedes transform/erasure/retention in every job; full-refresh guard (`transform/macros/utils/guards.sql`, on-run-start + `should_full_refresh` override; unset `LAKEHOUSE_ENV` counts as prod; stack 22 sets it); release runbook (`iac docs/compliance/runbooks/patching.md:27-57`, `docs/releases.md`) | R3-4 (low gaps in the runner) |
| N-6 deregistration vs bookkeeping | **FIXED (per the user's decision)** | `scope = deregistration`: `delete` tables with their own time rule are anonymised (subject column + `anonymise_columns` set to NULL, `_anonymised_at` set) until their retention expires (`plan.py:112-130,207-212`); migration V0002 adds the marker | - |
| N-7 lost requests / batch abort | **FIXED** | a request is kept and marked `failed` until it fully succeeds; the batch continues and raises `ErasureBatchError` at the end (`executor.py:456-490`); dequeue purges the queue's own versions | - |
| N-8 dry run writes | **FIXED** | commit `997ce69`: no queue row, no purge in dry run | - |
| N-9 silent missing audit row | **FIXED** | commit `9706ce9` asserts the inserted row count | - |
| N-10 full-event redaction | **NOT FIXED** (low) | with `AUDIT_FULL_EVENTS=true` only `metadata.query` is redacted (`audit_sink.py:79-84`); the default is the redacted subset | redact `preparedQuery`, `failureInfo.failureMessage` too |
| N-11 break-glass | **FIXED** | `docs/releases.md:89` "Break-glass repair of protected schemas" | - |
| M-3 TLS residual | **ACCEPTED RESIDUAL** | unchanged since round 2 | - |
| L6 RustFS PDB | **NOT FIXED** (low) | no PDB in `modules/rustfs/main.tf` | - |
| L7 root token for Tofu | **FIXED** | scoped `tofu-deployer` policy, short-lived token minted from root in dev and revoked afterwards (`scripts/lib/openbao.sh:79-...`, `scripts/openbao/tofu-deployer.hcl`) | R3-5: the policy is still root-equivalent through ACL and role management |
| L1 out-of-band dev objects | **FIXED** | see section 1 | - |
| L4 Helm chart (dispute) | **ACCEPTED** (unchanged) | - | - |

## 3. New defects (round 3)

### HIGH

**R3-1. Any Dagster UI user can run arbitrary code with every pipeline secret, which defeats the purge guard, M-1 and the pepper isolation.** [medium-high: verified in the installed dagster-k8s source; I did not attempt it on the cluster] Owner: iac-data-plane (+ solution)

How it works:
- The K8sRunLauncher builds run Jobs with `include_run_tags=True`: `.venv/.../dagster_k8s/launcher.py:210`, `container_context.create_for_run`.
- A run tag `dagster-k8s/config` can therefore set:
  - `container_config.command` (kept by `job.py:910-921`; only `args` is forced at line 888);
  - `container_config.env_from` (the `lakehouse-purge-env` Secret);
  - `pod_template_spec_metadata.labels` (merged **last**, `job.py:950-955`, so it overrides `dagster/job`).
- Any member of `dagster_ui_groups` (default `platform-admin`, `data-engineer`; Dagster OSS has no roles) can add such a tag in the Launchpad.
- The Job is created by the launcher SA (`dagster`), so both purge-guard validations pass: the forged label is accepted, and the creator is the launcher.

What it gives a data engineer:
- shell in a run pod with `lakehouse-env`: the pepper, the S3 keys, and the `svc-dagster` password, i.e. groups `pii-reader` + `lakehouse-service`;
- plus the purge credential.

So a data engineer can unmask PII, write the protected keystore, erasure log and queue (undoing M-1), and permanently delete object versions. The verify checks only test the launcher with honest labels.

Fix:
- Set `runLauncher.config.k8sRunLauncher.only_allow_user_defined_k8s_config_fields` (supported by the installed dagster-k8s, `container_context.py:284-317`) so that run and job tags may only set what the solution needs, e.g. `{container_config: {env_from: true}}`; no `command`, no labels.
- Make the admission guard also require that the Job's container `command` is empty or equals the launcher's.
- Restrict `dagster_ui_groups` in test/prod to an operator group, and treat Dagster UI access as equivalent to the `svc-dagster` identity in the access-review runbook.
- Add a verify probe that launches a run with a forged `dagster-k8s/config` tag and expects a refusal.

**R3-2. Publishing a solution release is not fully scripted, and there is no scripted air-gap path for the solution artefacts.** [high] Owner: solution (scripts) + iac-ops (runbook)

Manual host setup the scripts do not do:
- `scripts/push-image.sh` relies on `podman push --tls-verify=true` with system trust, and `scripts/push-opa-bundle.sh` calls `oras push` with no CA option (only `--plain-http`). Neither installs or passes the Zot registry CA.
- On this host the CA was put into `/etc/containers/certs.d/registry.dev.lakehouse.internal:5000/ca.crt` by hand (2026-11-18 13:50); no script in either repo writes `certs.d` (`grep -rn certs.d` finds nothing).
- `NO_PROXY` for the registry and `SSL_CERT_FILE` for oras are likewise left to the operator. The IaC `scripts/lib/common.sh:72-94` builds a trust bundle and `NO_PROXY` only for IaC scripts.
- `BUILD_CA_BUNDLE`/`BUILD_PROXY` are handled by `build-image.sh:11-32`, but neither `docs/releases.md` nor `iac docs/data-plane.md:29-36` (which shows only `make image image-push bundle bundle-push` plus credentials) mentions any of this.

The air-gap gap:
- For an air-gapped prod there is no scripted transfer of the solution image, its cosign signature and the OPA bundle into the prod Zot.
- `scripts/airgap/mirror.sh` covers only the locked upstream images and charts (no `boccob/` handling).
- `make image-push` assumes the build host reaches the target Zot.
- This contradicts "ALL deployment done via scripts" and the air-gap decision D12.

Fix:
- In `scripts/lib.sh` (solution), add a `registry_trust` step: take `REGISTRY_CA_FILE`, pass `--cert-dir` to podman (a temp dir holding `ca.crt`) and `--ca-file` to oras, and add the registry to `NO_PROXY`.
- Have IaC export `REGISTRY_CA_FILE` (already in `common.sh:65`) through a `make release-publish ENV=..` wrapper that calls the solution's make targets.
- Add `boccob/*` artefacts (image, signature, attestation, bundle, by digest) to `mirror.sh bundle/load`, or add a `make solution-bundle` / `solution-load` pair.
- Document all of it in the patching runbook.

### MEDIUM

**R3-3. Irreplaceable OpenBao mounts can be destroyed by an auto-approved apply.** [high] Owner: iac-foundation
- `vault_mount.kv` (`modules/openbao-config/main.tf:7-12`), the PKI and transit mounts and the Kubernetes auth backend have no `lifecycle { prevent_destroy = true }`.
- The new `tofu-deployer` policy grants `delete` on `sys/mounts/kv`, `pki`, `pki_int` and `transit` (`scripts/openbao/tofu-deployer.hcl`).
- `scripts/deploy.sh` runs `apply -auto-approve`, so a change that forces replacement (e.g. of `kv_mount` or the mount options) wipes every KV secret. That includes the pseudonymisation pepper, whose loss breaks every pseudonymised key, and the cosign transit key. Nobody reviews the plan.
- The only recovery is the hourly raft snapshot.
- Fix: `prevent_destroy` on these resources; drop `delete` on `sys/mounts/kv` and `transit` from `tofu-deployer`; have `deploy.sh` refuse plans with deletions or replacements of `vault_*` resources unless `ALLOW_DESTROY=<env>`.

### LOW
- **R3-4** (solution) Migration runner gaps:
  - `schema_drift` checks only column *presence*, so a retyped column that `append_new_columns` ignores is not caught;
  - a migration run outside Dagster (`lakehouse-migrate` CLI or `make dbt-build` from the solution Makefile) is not serialised by the `lakehouse_writer` pool, and `make dbt-build` skips the migrations entirely;
  - the checksum covers comments, so editing a comment of an applied migration blocks every release (strict, but document it).
  - Injection risk is negligible: placeholders are allow-listed catalog identifiers, files ship in the image. Idempotency is by convention (`IF EXISTS`) and not enforced; a non-idempotent statement that fails half-way would need a manual fix.
  - Fix: compare data types too; take a Trino-side lock (e.g. insert a lock row into the protected record table) in `run_migrations`; make `make dbt-build` run `lakehouse-migrate` first.
- **R3-5** (iac-foundation) `tofu-deployer` can create any ACL policy except its own (`sys/policies/acl/*`) and any Kubernetes-auth role (`auth/kubernetes/role/*`). A tofu run can therefore grant itself, or any ServiceAccount, `kv/*` read: the policy is root-equivalent, and the comment's "no secret values" is a convention, not a boundary. Fix: document it as privileged and require four-eyes review of OpenBao plans (see R3-3).
- **R3-6** (iac-data-plane/foundation) Platform pods have no `ephemeral-storage` requests or limits ("request is 0" in the eviction messages); under node disk pressure, arbitrary platform pods are evicted, and the evicted pods remain and fail `make verify`. Fix: set ephemeral-storage requests/limits in the LimitRange (`namespace-baseline`); clean up evicted pods, or exclude `reason=Evicted` with a warning in verify.
- **R3-7** (iac-foundation) `STATE_READ_UNENCRYPTED=1` (`scripts/tofu.sh:68-79`) is safe for writes: aes_gcm stays the primary method and the `unencrypted` method is only a read fallback, so it cannot write plaintext state (verify "tofu state is encrypted" PASS; no plaintext state files were found under `/root/.boccob` or elsewhere on disk). But nothing warns, and `deploy.sh` does not refuse it. If left exported, every apply silently accepts a plaintext (unauthenticated) state from the `tofu-state` Secret, losing AES-GCM's tamper protection. Fix: `warn` when set, refuse `apply`/`plan` with it set (allow only `state push|pull|list`), and document `unset` in the state-mv procedure.
- **N-10** carried (full-event redaction), **L6** carried (RustFS PDB).

### Checked, no defect
- **7-day window vs. erasure claims.** Consistent:
  - `docs/gdpr.md:136-144,189-203` and `control-mapping.md:17-20` say that ordinary deletes stay recoverable for `NONCURRENT_VERSION_GRACE_DAYS`/`lakehouse_noncurrent_version_days` (7);
  - the erasure purges versions at once only under the touched table locations and the subject's raw files;
  - copies elsewhere (e.g. files of dropped `__dbt_tmp` tables) expire within the window and are declared backup-like.
  - The code matches: maintenance uses `older_than = now - max(grace, orphan)`, retention does plain deletes, and the erasure purges by prefix (`executor.py:337-341`). One value feeds both the lifecycle and the env (`a75c28e`).
  - This is a documented controller decision ([DPO/legal review]), not a defect.
- **Purge-guard admission policies against the threats they name.** Sound: a compromised run pod (SA `dagster-code-...-user-deployments`, which may create Jobs and Pods but cannot read Secrets) is refused, which verify proves. They also cover UPDATE and ephemeral containers. They do not stop R3-1, because the attacker there is the legitimate launcher.
- **dbt leftovers.** dbt-trino drops pre-existing `__dbt_tmp` relations, and the erasure drops work tables. Leftovers no longer break later jobs.

## 4. Updated traceability (rows that changed since AUDIT-2; all other rows unchanged = MET)

| # | Requirement / decision | AUDIT-2 | AUDIT-3 | Reason |
|---|---|---|---|---|
| R1 | Enterprise-grade, compliant | PARTIAL | **PARTIAL** | R3-1 (privilege escalation through the Dagster UI), R3-3 |
| R14 | All deployment via scripts | MET | **PARTIAL** | R3-2: publishing a release needs undocumented manual trust/proxy setup on the build host |
| R23 | Releases evolve schemas without data loss | NOT MET | **MET** | migrations, `append_new_columns`, full-refresh guard, migrate job (3 successful `migrate` runs on dev) |
| D1 | GDPR/DPA/NIS2/ISO | PARTIAL | **PARTIAL** | R3-1; MFA still off by default (documented residual) |
| D7 | Backup and DR | PARTIAL | **MET** | N-2, N-3, N-4 fixed; `make backup WHAT=lake`; verify backup checks PASS (lake rollback is limited to the 7-day version window, documented) |
| D12 | dev/test/prod air-gapped from one module set | UNVERIFIED | **PARTIAL** | the upstream air-gap path exists, but there is no scripted air-gap transfer of the solution artefacts (R3-2) |
| D18e | Scripted erasure | PARTIAL | **MET** | N-1, N-2, N-7, N-8, N-9 fixed; 7 completed `erasure` runs on dev; residue outside touched tables is bounded at 7 days and documented |
| D19 | Synthetic e2e demo | UNVERIFIED | **MET** | live evidence: `daily_refresh` 6/6, `migrate` 3/3, `erasure` 7/7 succeeded on dev; verify 99/100 (the one failure is environmental); the worker reports e2e 36/36, which I did not re-run because it writes data |

### Status counts (47 rows: 23 requirements, 24 decisions)
- Requirements (23): **MET 20**, **PARTIAL 2** (R1, R14), **UNVERIFIED 1** (R3: test/prod hosts), **NOT MET 0**
- Decisions (24): **MET 20**, **PARTIAL 2** (D1, D12), **UNVERIFIED 2** (D2 test/prod hosts, D13 HA), **NOT MET 0**
- **Total: MET 40, PARTIAL 4, UNVERIFIED 3, NOT MET 0**
- Lead defaults (10): MET 10

## 5. Finding statuses (summary)
- AUDIT-2 items: **fixed 10** (N-1, N-2, N-4, N-5, N-6, N-7, N-8, N-9, N-11, L7), **fixed but bypassable 1** (N-3, see R3-1), **not fixed 2, both low** (N-10, L6), accepted residual or dispute 2 (M-3, L4), L1 fixed.
- New in round 3: **2 high** (R3-1, R3-2), **1 medium** (R3-3), **4 low** (R3-4..R3-7). No critical finding.
