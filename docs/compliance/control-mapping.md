# Control mapping

Columns: **Requirement** (paraphrased, not quoted) · **Technical control in
these repositories** · **Evidence** · **Residual organisational
responsibility** (what software cannot do). IaC paths are relative to this
repository; `solution:` paths are in `project-boccob`. Requirements are
summarised for orientation only — the legal texts are authoritative
**[DPO/legal review]**.

## 1. GDPR (Regulation (EU) 2016/679)

| Requirement | Technical control | Evidence | Residual responsibility |
|---|---|---|---|
| **Art. 5(1)(a)** lawfulness, fairness, transparency | none technical beyond logging of access (see Art. 30/32) | — | legal basis per purpose, privacy notices, records of processing |
| **Art. 5(1)(b)/(c)** purpose limitation, data minimisation | column classification in dbt meta, CPR confined to one governed column, pseudonymised keys from `clean` onward (solution: `docs/gdpr.md`, `make check-classification`); OPA column masks by role (solution OPA bundle, `modules/opa`) | classification lint, OPA policy tests (`make opa-test`), integration test "no CPR outside clean" | decide which data is necessary for which purpose; approve the classification |
| **Art. 5(1)(d)** accuracy | rectification flows through the source systems and re-ingestion (raw immutable, clean rebuilt by dbt) | dbt runs (Dagster run history) | rectification process with the source owner |
| **Art. 5(1)(e)** storage limitation | per-layer retention (solution: `governance/retention.yml`, Dagster job `retention`); log retention per Loki tenant (`log_retention_period`, `audit_retention_period` in `stacks/30-observability`); backup retention (`retention_policy`, `openbao_snapshot_retention_days`, `noncurrent_version_retention_days` in `stacks/32-backup`) | Dagster retention run log; Loki runtime config; S3 lifecycle rules on `platform-backup` | set the retention periods (incl. for logs and backups, which also contain personal data) **[DPO/legal review]** |
| **Art. 5(1)(f)** integrity and confidentiality | see Art. 32 | see Art. 32 | see Art. 32 |
| **Art. 5(2)** accountability | audit trail (Kubernetes API, OpenBao, Keycloak events, Trino, OPA decisions, Polaris, Kyverno) in Loki tenant `audit`, WORM archive `platform-audit`; everything as code in git | `make verify` audit checks; daily manifests in `s3://platform-audit/loki-audit/<day>/` | demonstrate compliance (policies, DPIA, records, training) |
| **Art. 15/16/17** access, rectification, erasure | erasure tooling: Iceberg row deletes + snapshot expiry + raw file removal (solution: `governance/erasure`, CLI `lakehouse-erase`, Dagster job `erasure`, audit table); subject lookup by pseudonymised key | erasure audit table; Dagster run log | handle requests (identity check, deadlines, exemptions). Erased data can persist (a) as **noncurrent object versions** in the versioned lakehouse buckets: the RustFS lifecycle removes them after `lakehouse_noncurrent_version_days` (stack 12, default 1 day; `make verify` checks the rule on all four buckets) and the solution's erasure job deletes the versions of the touched files explicitly; (b) in the **off-site copy** of the lake buckets (`stacks/32-backup` `offsite.buckets`, deletions are not propagated: the target's own retention applies); (c) in PostgreSQL/OpenBao backups until their retention expires. Document (b)/(c) in the erasure procedure and re-apply erasure after any restore **[DPO/legal review]** |
| **Art. 25** data protection by design and by default | default-deny NetworkPolicies (`modules/namespace-baseline`), PSS `restricted`, OIDC SSO with group-based roles (Keycloak, `modules/keycloak`), OPA fine-grained access with PII masking by default, pseudonymisation, Kyverno admission policies (`stacks/31-policy`) | `make verify` (NetworkPolicy, Pod Security, Kyverno checks); policy reports | DPIA where required (art. 35); role design and approval |
| **Art. 28** processor | the platform runs on-prem; no processor is introduced by the software itself | — | contracts with hosting/operations providers, off-site backup provider (`offsite` target in `stacks/32-backup`) and any support vendor |
| **Art. 30** records of processing | technical inputs: classification metadata (dbt meta), data flows as code (Dagster assets, dbt lineage), access logs | dbt docs / lineage, `governance/` in the solution repo | maintain the records (the software does not produce an art. 30 register) |
| **Art. 32** security of processing | encryption in transit (TLS on every hop between namespaces and to clients, OpenBao PKI + cert-manager; intra-namespace plaintext exceptions in `docs/data-plane.md` "TLS exceptions"), at rest (k3s secrets encryption; SSE-S3 for backups and the audit archive: `modules/rustfs` `sse_master_key_secret`); pseudonymisation; access control (Keycloak, OPA, OpenBao policies, Kubernetes RBAC); availability and resilience (HA profile, backups, `make restore-test`); regular testing (`make verify`, Kyverno reports, Trivy) | `make verify ENV=<env>` output; `make restore-test`; Trivy reports `~/.cache/boccob/reports/<env>/trivy` | risk assessment that sizes these measures; storage-level encryption of node disks and RustFS data volumes (not provided by this repo: use encrypted disks/CSI) **[residual]** |
| **Art. 33/34** breach notification | detection inputs: alert rules (`stacks/30-observability`), audit trail, Kyverno violations; evidence preservation (WORM archive) | Alertmanager history, audit archive | assess, notify Datatilsynet within 72 h where required, inform data subjects when high risk — see `runbooks/incident-response.md` **[DPO/legal review]** |
| **Art. 44 ff.** transfers / data residency | all components on-prem, air-gapped (no runtime egress; images from Zot), off-site copy target is a variable (`offsite` in `stacks/32-backup`) | `make verify` "images only from the Zot mirror", NetworkPolicies | choose the off-site location inside the EU/EEA or with a valid transfer mechanism; vendor support access **[DPO/legal review]** |

## 2. Danish Data Protection Act (databeskyttelsesloven)

| Requirement | Technical control | Evidence | Residual responsibility |
|---|---|---|---|
| **CPR numbers (§ 11)**: processing only on the conditions of the Act | CPR in exactly one classified column (`clean.<source>.citizens.cpr_number`, `cpr: true`), HMAC pseudonymisation with a pepper from OpenBao, masked by OPA except for `pii-reader`, never propagated to consolidated/curated (solution: `docs/gdpr.md`) | integration tests, OPA tests, classification lint | determine whether the legal conditions for processing CPR are met for each purpose, and who may unmask **[DPO/legal review]** |
| Sensitive data / criminal offences (§ 7, § 8) | same classification (`sensitive`) and masking mechanisms | as above | classification decisions, legal basis |
| Supervisory authority: Datatilsynet | — | — | notifications (GDPR art. 33) go to Datatilsynet |

## 3. NIS2 (Directive (EU) 2022/2555), Art. 21(2) measures

Denmark implements NIS2 in national law; which obligations apply depends on the
entity's classification (essential / important) **[DPO/legal review]**.

| Measure | Technical control | Evidence | Residual responsibility |
|---|---|---|---|
| (a) risk analysis, information security policies | everything as code and reviewable (git); `docs/` | git history | risk analysis, policies, management approval (Art. 20) |
| (b) incident handling | alerts (`stacks/30-observability`: OpenBao sealed, certificates, backups, targets down, log pipeline), central audit trail, WORM archive, `runbooks/incident-response.md` | Alertmanager, Loki tenant `audit` | incident response organisation, 24 h / 72 h / 1 month reporting (Art. 23) to the national CSIRT/authority |
| (c) business continuity, backup management, disaster recovery | continuous PostgreSQL backup (PITR), OpenBao snapshots, versioned buckets, off-site copy, k3s etcd snapshots (HA), RPO/RTO variables, `make backup|restore|restore-test` (`stacks/32-backup`, `scripts/backup/`) | `make restore-test` output (dev: PITR in 34 s), backup alerts | BC/DR plan, crisis management, periodic tests on test/prod, off-site location |
| (d) supply chain security | air-gapped Zot mirror, digest pinning (`versions.lock.yaml`), upstream signature verification at mirror time (`make verify-signatures`), cosign signing of solution artefacts with an OpenBao transit key (`make sign`), Kyverno admission: mirror-only, digest, no `latest`, signature of `boccob/*` images (`stacks/31-policy`) | Kyverno policy reports; `make verify` "images only from the mirror / pinned by digest" | supplier assessment, contracts, confirming the keyless signer identities in `scripts/supply-chain/signature-policy.yaml` (unverified in the sandbox) |
| (e) security in acquisition, development, maintenance; vulnerability handling | Trivy scans with an offline DB (`make scan`, `make trivy-db`), SBOMs (`make sbom`), version lock and `runbooks/patching.md` | scan reports, SBOMs | vulnerability management process, coordinated disclosure policy |
| (f) assessing effectiveness | `make verify`, `make restore-test`, Kyverno reports, Prometheus alerts | outputs kept as evidence | internal audit, management review |
| (g) cyber hygiene, training | hardening by default (PSS restricted, non-root, read-only rootfs, default-deny network) | Kyverno reports | training of staff and management (Art. 20(2)) |
| (h) cryptography, encryption | TLS between namespaces and to clients, documented intra-namespace exceptions in `docs/data-plane.md` (internal CA in OpenBao, ECDSA P-256/P-384), secrets encryption at rest, SSE-S3 on backups/audit archive, OpenTofu state encryption, OpenBao barrier encryption | `make verify` (PKI, state encryption, secrets encryption checks) | crypto policy, key custody (see `runbook-bootstrap.md` and `runbooks/key-rotation.md`) |
| (i) HR security, access control, asset management | Keycloak groups -> roles (Trino/OPA, Grafana, Polaris, Dagster), OpenBao policies, no static tokens in the cluster, inventory = `versions.yaml` + stacks | `runbooks/access-review.md` outputs | joiner/mover/leaver process, access reviews, asset register |
| (j) MFA, secured communications | OIDC SSO through Keycloak (MFA can be enforced in the realm); TLS for all communication | Keycloak realm config | enable and enforce MFA (realm required actions / authentication flow) — **not configured by default** |

## 4. ISO/IEC 27001:2022 Annex A (selection with a technical counterpart)

| Control | Technical control | Evidence | Residual responsibility |
|---|---|---|---|
| 5.15–5.18 access control, identity, authentication information, access rights | Keycloak SSO, groups `platform-admin`, `data-engineer`, `analyst`, `pii-reader`, `auditor`; OpenBao kubernetes auth (short-lived tokens); OPA; Grafana role mapping; audit Grafana restricted to `auditor` | Keycloak config, `runbooks/access-review.md` | access policy, approvals, reviews |
| 5.23 (cloud services) | not applicable to on-prem; off-site S3 target if a service is used | — | supplier agreement |
| 5.24–5.28 incident management, evidence | alerting, audit trail, WORM archive with hash-chained manifests (`modules/audit-archive`) | archive manifests, Loki | incident process, evidence handling (chain of custody) |
| 5.29–5.30 continuity, ICT readiness | backups, restore test, HA profile | `make restore-test` | BCP, exercises |
| 5.33 protection of records | object lock COMPLIANCE on `platform-audit` (verified: deletion refused even for the RustFS root user), versioning on all contract buckets | `make verify` "platform-audit has object lock" | retention schedule for records |
| 5.34 privacy and protection of PII | classification, masking, pseudonymisation, erasure (solution repo) | tests in the solution repo | privacy program |
| 8.2 privileged access | break-glass accounts in OpenBao KV, OpenBao root token revoked after bootstrap (runbook), Kubernetes admin kubeconfig only on the operator workstation | runbook records | PAM process, named admin accounts |
| 8.5 secure authentication | OIDC, PKCE for Grafana, no local login form in Grafana | Grafana config | MFA (see NIS2 (j)) |
| 8.7 protection against malware | image provenance controls (mirror, digest, signatures, scans) | Kyverno, Trivy | endpoint protection on hosts |
| 8.8 technical vulnerabilities | Trivy + SBOM, version lock, patch runbook | reports | patch SLAs |
| 8.9 configuration management | OpenTofu + Makefile, everything in git, Kyverno guardrails | git, `make plan` | change approval |
| 8.10 information deletion | erasure tooling, retention jobs, lifecycle rules | run logs | deletion policy incl. backups |
| 8.11 data masking | OPA column masks | OPA tests | masking rules approval |
| 8.13 information backup | `stacks/32-backup`, `scripts/backup/` | `make restore-test`, backup alerts | backup policy, off-site |
| 8.14 redundancy | HA profile (`ha = true`): 3 OpenBao raft members, 3 PostgreSQL instances, distributed RustFS, multi-replica controllers | `tofu validate` (HA not deployed in the sandbox) | test on real hosts |
| 8.15 logging | central logs + audit trail, separated tenants, variable retention | `make verify` Loki checks | log review procedure |
| 8.16 monitoring | Prometheus + Alertmanager, alert rules | Alertmanager | on-call, receivers (`alertmanager_config`) |
| 8.17 clock synchronisation | hosts must run time sync (prerequisite in `runbook-bootstrap.md`) | — | NTP on hosts |
| 8.20–8.22 network security, segregation | default-deny NetworkPolicies per namespace, explicit allows, namespaces per function, metrics openings by variable | `make verify` NetworkPolicy check | network zoning outside the cluster |
| 8.24 cryptography | see NIS2 (h) | | key management policy |
| 8.25–8.28 secure development | solution repo tests, Kyverno, signatures | CI-less: local test commands | SDLC policy |
| 8.31 separation of environments | dev/test/prod from one module set, separate clusters, state and secrets per environment | `environments/<env>` | environment access rules |
| 8.32 change management | version lock -> mirror -> deploy -> verify (`runbooks/patching.md`) | git history, verify outputs | CAB / approvals |

## 5. Known gaps (technical)

- Grafana and kube-state-metrics are implemented but not deployed in the build
  sandbox; Job/CronJob failure alerts need kube-state-metrics.
- Prometheus web endpoint is plain HTTP inside its namespace.
- HA profile, off-site copy to a real second site and k3s etcd snapshots were
  not exercised on real hosts.
- RustFS data volumes and node disks are not encrypted by this repository.
- MFA is not enforced in the Keycloak realm by default.
- The data-plane databases (`polaris-db`, `dagster-db`) still need
  `backup = …` (see `stacks/32-backup/README.md`); `make verify` reports it.
