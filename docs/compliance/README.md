# Compliance documentation

**What this is.** A map from regulatory and standards requirements to the
technical controls implemented in the two Boccob repositories (this IaC
repository and the solution repository `project-boccob`), with the evidence
each control produces and the organisational responsibility that remains.

**What this is not.** Legal advice, a certification, or a statement that an
organisation running this platform is compliant. Software can *support*
compliance with GDPR, the Danish Data Protection Act (databeskyttelsesloven),
NIS2 and ISO/IEC 27001:2022; it cannot make an organisation compliant.
Purposes, legal bases, retention periods, risk assessments, contracts,
notifications, training and management accountability are decisions and
duties of the controller / the entity. Every statement marked
**[DPO/legal review]** needs confirmation by the data protection officer or
legal counsel before it is relied upon.

| Document | Content |
|---|---|
| [control-mapping.md](control-mapping.md) | requirement -> technical control (paths, make targets, verify checks) -> evidence -> residual organisational responsibility |
| [runbooks/incident-response.md](runbooks/incident-response.md) | detection hooks, evidence preservation, NIS2 24 h / 72 h / 1 month and GDPR 72 h timelines |
| [runbooks/key-rotation.md](runbooks/key-rotation.md) | OpenBao (unseal/root, transit signing key), PKI, S3 keys, OIDC client secrets, database credentials, state passphrase |
| [runbooks/certificate-rotation.md](runbooks/certificate-rotation.md) | leaf certificates, issuing CA, root CA, bootstrap CA, registry CA |
| [runbooks/patching.md](runbooks/patching.md) | patch / upgrade through the version lock, scan, SBOM, signatures, rollback |
| [runbooks/access-review.md](runbooks/access-review.md) | periodic review of Keycloak groups, OpenBao policies, Kubernetes RBAC, S3 users, break-glass accounts |
| [runbooks/disaster-recovery.md](runbooks/disaster-recovery.md) | RPO/RTO, restore of PostgreSQL (PITR), OpenBao, object storage, cluster; restore test |

Status markers used in the runbooks: **[verified]** exercised on the dev
cluster in the build sandbox; **[static]** implemented and validated
(tofu validate, shellcheck, helm template) but not executed;
**[manual]** an organisational procedure without automation.

Evidence collection in one go (dev): `make verify ENV=dev` (cluster,
foundation, observability, audit, policy, backup and restore checks; exit code
and a PASS/FAIL list), `make restore-test ENV=dev`, `make scan`, `make sbom`,
`kubectl get policyreport -A`, the audit archive in `s3://platform-audit/`.
Keep the outputs with the date and the git commit of both repositories.
