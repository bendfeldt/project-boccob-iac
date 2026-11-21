# Boccob lakehouse: confirmation round 4

Date: 2026-11-21. Read-only. (Written incrementally.)

Solution HEAD: `61050ad`. IaC HEAD: `182834b`. Both working trees are clean. Free disk was ~1.5 GB, so only small logs were kept.

## 1. Status of AUDIT-3 findings

| ID | Status | Evidence |
|---|---|---|
| R3-1 Dagster run-tag injection | **FIXED** (low residual R4-1) | `CustomRunLauncher` with `only_allow_user_defined_k8s_config_fields` (`modules/dagster/main.tf:52-57,556-589`): no `command`, `args`, `image` or labels from tags; env names are limited to the contract (`only_allow_user_defined_env_vars`, enforced by dagster-k8s `container_context.py:373-399`). The ValidatingAdmissionPolicy `orchestration-dagster-run-jobs` (`main.tf:401-480`) applies to Jobs from the launcher SA: one container, no command, `dagster api execute_run|resume_run`, the code location image, `dagster/job` == `DAGSTER_RUN_JOB_NAME`, contract Secrets only, no projected volumes. `dagster_ui_groups = [platform-admin]` in test/prod. Allowing `resume_run` gives no bypass: it is the same entrypoint and image. Jobs created by other SAs are not run Jobs; the purge-secret guard still restricts them to the launcher SA |
| R3-2 release publish / air-gap | **FIXED** (low residual R4-2) | `make release-publish` (`scripts/release/publish.sh`) runs the solution targets with `REGISTRY_CA_FILE`, proxy and build CA, then signs and verifies. The solution's `registry_trust()` (`scripts/lib.sh:36-60`) passes the CA per call (`podman --cert-dir`, `oras --ca-file`, a temp `SSL_CERT_FILE`) and adds the registry to `NO_PROXY`, with no `/etc` writes. `make solution-bundle`/`solution-load` (`scripts/airgap/solution.sh`) move artefacts with their referrers, check SHA256SUMS and digests, and verify signatures with the target key. The push password reaches `podman/oras login` only via stdin (`printf | --password-stdin`) and the environment, never via process args or logs |
| R3-3 OpenBao mounts destroyable | **FIXED** | `prevent_destroy` on the KV, Kubernetes auth, PKI, PKI-int and transit resources (`modules/openbao-config/main.tf:16-88`, `stacks/31-policy/main.tf:77,91`); `tofu-deployer` has no `delete` on `sys/mounts/kv`/`transit`; `deploy.sh` plans to a file, refuses any delete or replace of `vault_*`, CNPG clusters, the RustFS release or PVCs unless `ALLOW_DESTROY=<env>`, then applies exactly that plan (`scripts/deploy.sh:38-92`). `replace_triggered_by` and `-replace` show up as delete actions in the plan JSON, so the guard catches them; `deploy.sh` passes no `-target`; `prevent_destroy` still blocks a direct `tofu.sh apply` |
| R3-4 migration runner | **FIXED** | type changes detected (`b856b14`); checksum over normalised SQL (`2166f79`); advisory lock row with a TTL in the protected schema, shared by the CLI and Dagster, race-safe (insert, then the oldest row wins) (`runner.py:302-326`); `make dbt-build` runs `scripts/dbt-build.sh` (migrate first; outside dev it refuses when migrations are pending) |
| R3-5 deployer root-equivalent | **FIXED (mitigated, documented)** | delete capabilities removed; ACL/role management remains (inherent), documented as privileged |
| R3-6 ephemeral storage | **FIXED** | LimitRange defaults: request 64Mi, limit 2Gi (`modules/namespace-baseline/variables.tf:126-129`); verify treats evicted pods and old CronJob runs as warnings |
| R3-7 STATE_READ_UNENCRYPTED | **FIXED** | allowed only for `state` subcommands, with a loud warning; every other action dies (`scripts/tofu.sh:72-77`) |
| N-10 full-event redaction | **FIXED** | `4f2a036`: every string field is redacted |
| L6 RustFS PDB | **FIXED** | `modules/rustfs/main.tf:145` `pdb = { create = var.distributed }`; lint renders the chart and asserts the PDB |

## 2. Checks
- solution `make lint`: PASS (127 columns classified). solution `make test`: PASS (pytest 87, OPA 41/41, Dagster validate).
- IaC `make lint`: PASS (all stacks valid, RustFS PDB render check, lock file).
- `make verify ENV=dev VERIFY_RESTORE_TEST=0`: **104 passed, 0 failed**. It includes the tag-injection probe ("forged dagster/job label is refused"), the run-job policy dry run (a custom command is refused), and the 3 purge-guard dry runs.

## 3. New defects from the round-4 changes (all LOW; none critical, high or medium)

- **R4-1** (iac-data-plane) The run-tag allowlist is still broader than the solution needs:
  - It allows `pod_spec_config.service_account_name` and `automount_service_account_token`; the run-job policy does not check the SA, so a tag can run a run pod as `dagster` (may create Jobs/Pods) or `eso-read`/`eso-push` (OpenBao roles of the namespace).
  - It allows any non-secret, non-projected volume type plus `volume_mounts`.
  - It allows contract env names with arbitrary values. Examples: `LAKEHOUSE_ENV`, `ERASURE_VERIFY_STORAGE=false`, `NONCURRENT_VERSION_GRACE_DAYS=0` (maintenance then purges at `max(0, orphan retention)` = 3-7 days instead of 7), `TRINO_HOST`/`S3_ENDPOINT_URL`, and the CA paths.
  - I found no code-execution path: the command and image are fixed and code comes only from the image. Since the only test/prod UI group is `platform-admin`, the impact is weakened verification or a shorter safety window by an admin.
  - Fix: drop `service_account_name`, `automount_service_account_token`, `security_context` and `namespace` from the allowlist (the container context sets them; the solution only needs `container_config.env_from`). Make the run-job policy require `serviceAccountName` == the run SA and only `configMap`/`emptyDir` volumes. Make safety-relevant env vars (`LAKEHOUSE_ENV`, `NONCURRENT_VERSION_GRACE_DAYS`, `ERASURE_VERIFY_STORAGE`) non-overridable by leaving them out of `only_allow_user_defined_env_vars`.
- **R4-2** (solution, plus iac-ops) The publish leaves the Zot push credential at rest: `oras login` (`push-opa-bundle.sh:26`) writes it to `~/.docker/config.json` (on this host: 0600, entry for `registry.dev.lakehouse.internal:5000`, written 2026-11-21 12:03); there is no logout. On a long-lived build host this is a standing push credential. Fix: a temporary `--registry-config` (oras) / `--authfile` (podman), removed by the `registry_trust` EXIT trap, or `logout` at the end.
- **R4-3** (iac-ops, process) For a prod `solution-load`, the dev signature fails the prod key check by design, and the runbook then says "re-sign with `make sign ENV=prod` after review". Nothing scripted checks the *source* signature before prod re-signs, so authenticity across environments rests on a human review plus SHA256SUMS. Fix: ship the source environment's public key in the bundle; have `load` verify against it, then sign with the target key in the same scripted step.

## 4. Traceability (rows changed since AUDIT-3; all others MET)

| # | AUDIT-3 | AUDIT-4 | Reason |
|---|---|---|---|
| R1 Enterprise-grade, compliant | PARTIAL | **MET** | R3-1 and R3-3 fixed; the remaining residuals are documented organisational controls (D1) |
| R14 All deployment via scripts | PARTIAL | **MET** | `make release-publish`, `solution-bundle`/`solution-load`; no manual host trust setup needed |
| D1 GDPR/DPA/NIS2/ISO | PARTIAL | **PARTIAL** | MFA not enforced in the Keycloak realm by default (documented [manual] control); DPO/legal decisions (retention periods, the 7-day window) are open by design |
| D12 Air-gapped dev/test/prod | PARTIAL | **MET** (static for prod) | scripted air-gap path for upstream and solution artefacts; prod never run |

**Counts (47 rows):** requirements (23): MET 22, UNVERIFIED 1 (R3 test/prod hosts); decisions (24): MET 21, PARTIAL 1 (D1), UNVERIFIED 2 (D2 hosts, D13 HA). **Total: MET 43, PARTIAL 1, UNVERIFIED 3, NOT MET 0.** Lead defaults: MET 10/10.

**Findings:** all 9 AUDIT-3 items **fixed** (R3-1..R3-7, N-10, L6). New: 3 low (R4-1..R4-3). Open critical/high/medium: **none**.
