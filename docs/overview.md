# What was built and why

This page is the map of the platform for someone new to the project. Read it once from top to
bottom; every section links to the document with the details. To set the platform up on your
machine, follow [getting-started.md](getting-started.md). Unknown words are explained in the
[glossary](#glossary) at the end.

## 1. The problem

A public authority wants a **lakehouse**: one place where data from its source systems is stored,
cleaned and made available for analysis with SQL. The data contains personal data, including Danish
CPR numbers. So the platform must:

- run **on premises** and **air-gapped**: the servers have no internet access at all, so every
  container image and chart must be brought in and pinned in advance;
- use **open-source** components only;
- protect personal data: pseudonymise identifiers, mask columns per role, erase a person on request
  (GDPR art. 17), keep audit logs that cannot be changed;
- be rebuildable from code: every server, setting and permission is in git; secrets are not.

## 2. Two repositories and how they meet

The work is split into two repositories that share **no files**. Clone them next to each other
(e.g. `~/src/project-boccob-iac` and `~/src/project-boccob`).

| Repository | Owns | Tools |
|---|---|---|
| `project-boccob-iac` (this one) | the **platform**: cluster, registry, storage, catalog, SQL engine, scheduler, secrets, login, monitoring, policies, backups | OpenTofu, bash, Makefile |
| `project-boccob` (the solution) | the **data code**: ingestion, transformations, access policies, GDPR jobs | dlt, dbt, Dagster, OPA (Rego), Python |

They meet in exactly three places:

```
  project-boccob (solution)                                   project-boccob-iac (platform)
  -------------------------                                   -----------------------------
                         (1) make publish
  code location image  ----------------------->  Zot registry  <boccob/dagster-code-location@sha256:..>
  OPA policy bundle    ----------------------->  (dev: on      <boccob/opa-policy-bundle@sha256:..>
                                                  your machine)          |
                                                                         | (2) make sign, digests into
                                                                         |     environments/<env>/21-query.tfvars
                                                                         |     and 22-orchestration.tfvars,
                                                                         v     make deploy
                                                              Trino + OPA (stack 21), Dagster (stack 22)

                         (3) make dev-env ENV=dev
  make publish / e2e   <-----------------------  ~/.boccob/dev/developer.env
  (BOCCOB_PLATFORM_ENV)                          (registry, CA, endpoints, test users; outside both checkouts)
```

1. The solution builds two **artefacts** and pushes them to the platform's registry.
2. The platform **signs** them with its own key and deploys them **by digest** (a fixed content
   hash, so exactly the tested bytes run).
3. The platform writes one **environment file** for the solution's developer tools. Its keys are
   the contract: [developer-interface.md](developer-interface.md) here, `docs/platform-contract.md`
   section 4 in the solution.

Neither repository reads a file of the other. If you find yourself wanting a path into the other
checkout, use one of these three interfaces instead.

## 3. The components

Everything runs on **k3s**, a small Kubernetes distribution. On dev the whole cluster is one
Podman container on your machine; on test/prod it is installed on servers.

| Component | What it is | Why it is here | Configured in | See it working |
|---|---|---|---|---|
| **Zot** | container registry | the cluster pulls images **only** from here (air-gap) | `scripts/cluster/registry-up.sh`, `versions.lock.yaml` | `make airgap-check ENV=dev` |
| **k3s** | Kubernetes, hardened per the CIS guide | runs everything else | `scripts/lib/k3s-config.sh`, `scripts/cluster/` | `kubectl get nodes` |
| **Traefik** | ingress (HTTPS entry point), bundled with k3s | one TLS front door for all web UIs and APIs | stack `00-bootstrap` | `https://<svc>.dev.lakehouse.internal` |
| **cert-manager** | issues TLS certificates | every hop is TLS | stack `00-bootstrap`, `11-foundation-pki` | `kubectl get certificate -A` |
| **External Secrets Operator** (ESO) | copies secrets from OpenBao into Kubernetes Secrets | no secret value in git | stack `00-bootstrap`, `modules/generated-secret`, `modules/external-secret` | `kubectl get externalsecret -A` |
| **CloudNativePG** | PostgreSQL operator | databases for Keycloak, Polaris, Dagster, with backups | stack `00-bootstrap`, `modules/postgres-cluster` | `kubectl -n database get clusters.postgresql.cnpg.io` |
| **OpenBao** | secrets store and internal certificate authority (fork of Vault) | holds every generated password, the PKI and the signing key | stacks `10-foundation-secrets`, `11-foundation-pki` | `https://openbao.dev.lakehouse.internal`, `make openbao-unseal` |
| **RustFS** | S3-compatible object storage | the lake buckets, backups, logs | stack `12-foundation-services`, `modules/rustfs` | `https://s3-console.dev.lakehouse.internal` |
| **Keycloak** | login server (OIDC, single sign-on) | people log in once; groups decide what they may do | stack `13-identity`, `modules/keycloak` | `https://keycloak.dev.lakehouse.internal` (realm `lakehouse`) |
| **Polaris** | Iceberg REST catalog | knows where every table is | stack `20-catalog`, `modules/polaris` | `https://polaris.dev.lakehouse.internal` (API only) |
| **Trino** | SQL engine | people and dbt query the lake with SQL | stack `21-query`, `modules/trino` | `https://trino.dev.lakehouse.internal` |
| **OPA** | policy engine | decides per query what a user may see (masking, row filters) | stack `21-query`, `modules/opa`; policies from the solution | `make verify` (data-plane checks) |
| **Dagster** | orchestrator | runs the solution's jobs on schedules | stack `22-orchestration`, `modules/dagster` | `https://dagster.dev.lakehouse.internal` |
| **oauth2-proxy** | login in front of Dagster | Dagster OSS has no login of its own | stack `22-orchestration`, `modules/oauth2-proxy` | the Dagster URL asks for Keycloak |
| **Prometheus + Alertmanager** | metrics and alerts | health, sealed OpenBao, certificates, backups | stack `30-observability` | `kubectl -n observability get pods` |
| **Loki + OpenTelemetry Collector** | log store and log shipper | central logs, separate audit tenant | stack `30-observability` | see [stacks/30-observability](../stacks/30-observability/README.md) |
| **Grafana** | dashboards | optional; **off on dev** (image size) | stack `30-observability` (`grafana_enabled`) | test/prod only |
| **Kyverno** | admission policies | only signed, digest-pinned, non-root images may run | stack `31-policy` | `kubectl get policyreport -A` |
| **Backup jobs** | PostgreSQL backups, OpenBao snapshots, off-site copies | disaster recovery | stack `32-backup`, `scripts/backup/` | `make restore-test ENV=dev` |

Versions of all of these are pinned in [versions.yaml](../versions.yaml) and resolved to digests in
`versions.lock.yaml` ([versions.md](versions.md)). Design details: [architecture.md](architecture.md)
(cluster and foundation) and [data-plane.md](data-plane.md) (Polaris, Trino, OPA, Dagster).

## 4. The stacks, in order

A **stack** is one OpenTofu project in `stacks/NN-name/` with its own state. `make deploy ENV=<env>`
applies them in number order. They are split because some things must exist before others can even
be planned (custom resource definitions, an unsealed OpenBao). Stacks never read each other's
state; they rely on fixed, well-known names (`stacks/_shared/common.tf`).

| Stack | Namespace(s) | Deploys |
|---|---|---|
| `00-bootstrap` | `platform-system` | cert-manager, External Secrets, CloudNativePG operator; Traefik hardening; CoreDNS rewrite |
| `10-foundation-secrets` | `secrets` | bootstrap CA, OpenBao (created sealed; then `scripts/openbao/init.sh` initialises and unseals it) |
| `11-foundation-pki` | `platform-system` | OpenBao configuration: KV store, Kubernetes login, root and issuing CA, ClusterIssuer `openbao-pki`, per-namespace secret access |
| `12-foundation-services` | `database`, `storage` | RustFS with the buckets and S3 users; database namespace with backup credentials; ingress for S3 and OpenBao |
| `13-identity` | `identity` | Keycloak, realm `lakehouse`, groups, OIDC clients, database `keycloak-db` |
| `20-catalog` | `catalog` | Polaris, its database, the four catalogs `raw`, `clean`, `consolidated`, `curated`, principals `trino` and `ingest` |
| `21-query` | `query` | Trino and OPA (with the solution's policy bundle) |
| `22-orchestration` | `orchestration` | Dagster, the solution's code location image, oauth2-proxy, database `dagster-db`, the pseudonymisation pepper |
| `30-observability` | `observability`, `observability-agent` | Prometheus, Alertmanager, Loki, log collector, audit archive, Grafana (off on dev) |
| `31-policy` | `kyverno` | Kyverno, the policy set, the cosign signing key (OpenBao transit) |
| `32-backup` | `backup` | OpenBao snapshots, off-site copies, backup lifecycle rules |

Each stack has a README in its folder. Stacks 21 and 22 need the solution's two artefacts, which is
why the very first deployment goes in two rounds ([getting-started.md](getting-started.md), step 8).

## 5. Environments: dev, test, prod

Settings per environment live in `environments/<env>/`: `env.sh` (for the scripts) and
`<stack>.tfvars` (for OpenTofu). See [environments/README.md](../environments/README.md).

| | dev | test | prod |
|---|---|---|---|
| Cluster | one k3s node in a Podman container on your machine (`boccob-dev-server-0`) | k3s on servers: 3 servers + agents, installed over SSH | same as test |
| Registry | Zot container next to it (`registry.dev.lakehouse.internal:5000`, macOS `:5050`) | Zot on a registry host (`registry.test.lakehouse.internal:5000`) | `registry.prod.lakehouse.internal:5000` |
| Base domain | `dev.lakehouse.internal` | `test.lakehouse.internal` | `prod.lakehouse.internal` |
| Sizing (`ha`) | single replicas | HA: 3 OpenBao, 3 PostgreSQL, distributed RustFS, Trino workers | same as test |
| OpenBao unseal | 1 key, stored in `~/.boccob/dev/openbao/` | 5 shares, 3 needed, PGP-encrypted to custodians | same |
| OpenTofu state | local file, `~/.boccob/dev/tofu/state/` | S3 bucket outside the site | same |
| Kyverno | `Audit` (reports only) | `Enforce` (rejects) | `Enforce` |
| Schedules of the solution | off (`schedules_enabled = false`) | on | on |
| Supply-chain checks while mirroring | skipped (`SKIP_SUPPLY_CHAIN=1`) | on | on |
| Test users, `developer.env` | yes (`make dev-env`) | no | no |
| Dagster UI groups | `platform-admin`, `data-engineer` | `platform-admin` only | `platform-admin` only |
| Tested | yes (Linux x64) | no (no hosts available) | no |

## 6. Security and compliance on one page

| Topic | How it works | Details |
|---|---|---|
| **Secrets** | Passwords are generated inside the cluster, pushed once to OpenBao (`kv/<namespace>/<name>`) and read back into Kubernetes Secrets by ESO. OpenBao is the source of truth. Nothing secret is in git, tfvars or OpenTofu state. Local secrets of your machine are in `~/.boccob/<env>/` (mode 0700), outside both checkouts | [conventions.md](conventions.md) §5, [modules/generated-secret](../modules/generated-secret/README.md) |
| **PKI** | A bootstrap CA only for OpenBao's own certificate; then OpenBao's root CA (EC P-384) and issuing CA sign every other certificate through cert-manager (90 days, renewed at 60). The CA bundle is in the ConfigMap `platform-ca` of each namespace and in `~/.boccob/dev/pki/` | [architecture.md](architecture.md) "Trust and secrets", [compliance/runbooks/certificate-rotation.md](compliance/runbooks/certificate-rotation.md) |
| **SSO groups** | Keycloak realm `lakehouse` with groups `platform-admin`, `data-engineer`, `analyst`, `pii-reader`, `auditor`. Tokens carry a `groups` claim; Trino, Dagster (via oauth2-proxy) and Grafana use it | [conventions.md](conventions.md) §8, [modules/keycloak](../modules/keycloak/README.md) |
| **OPA masking** | Trino asks OPA for every query. The solution's policy masks personal-data columns for users without `pii-reader` and limits each group to its layers. Trino gets group membership from Keycloak through a sync sidecar | [data-plane.md](data-plane.md) "Trino + OPA"; solution `docs/gdpr.md` |
| **Network** | Every namespace starts with default-deny for ingress and egress; each allowed flow is listed. Every hop that leaves a namespace is TLS; three in-namespace hops are documented exceptions | [conventions.md](conventions.md) §10, [data-plane.md](data-plane.md) "TLS exceptions" |
| **Pod Security** | Namespaces enforce the Kubernetes Pod Security Standard `restricted` (non-root, no privileges); one log collector namespace is `privileged` by design | [architecture.md](architecture.md) |
| **Kyverno** | Images only from Zot, pinned by digest, never `latest`; non-root; read-only root filesystem; requests and limits; solution images signed with the platform key | [stacks/31-policy](../stacks/31-policy/README.md) |
| **Supply chain** | Upstream signatures are checked and images scanned (Trivy) when they are mirrored (test/prod); SBOMs with syft; solution artefacts signed by the platform (`make sign`) | [compliance/runbooks/patching.md](compliance/runbooks/patching.md) |
| **Audit logs** | Kubernetes API, OpenBao, Keycloak, Trino queries, OPA decisions go to the Loki tenant `audit`; every night the previous day is exported to the bucket `platform-audit` with object lock (cannot be deleted, not even by the storage admin) and a hash chain | [stacks/30-observability](../stacks/30-observability/README.md) |
| **Backups** | PostgreSQL continuous backup (point-in-time restore), OpenBao snapshots, off-site copies of backups and of the lake; `make restore-test` proves a restore | [stacks/32-backup](../stacks/32-backup/README.md), [compliance/runbooks/disaster-recovery.md](compliance/runbooks/disaster-recovery.md) |
| **Compliance mapping** | GDPR, Danish Data Protection Act, NIS2, ISO 27001 → technical control → evidence → what the organisation must still do | [compliance/README.md](compliance/README.md) |

## 7. Day-2 operations

| Task | Command or document |
|---|---|
| Health check | `make verify ENV=<env>` |
| Start again after a reboot (dev) | `make cluster-up ENV=dev` (also unseals OpenBao) |
| OpenBao sealed | `make openbao-unseal ENV=<env>` (test/prod: three custodians) |
| See what a change does | `make plan ENV=<env> STACK=<stack>` |
| Upgrade a component | edit `versions.yaml` → `make lock` → `make airgap-mirror` → `make deploy STACK=..` ([compliance/runbooks/patching.md](compliance/runbooks/patching.md)) |
| Deploy a solution release | [compliance/runbooks/patching.md](compliance/runbooks/patching.md) "Solution release"; on dev: [getting-started.md](getting-started.md) step 8 |
| Backups and restore test | `make backup ENV=<env>`, `make restore-test ENV=<env>` |
| Rotate a secret or key | [compliance/runbooks/key-rotation.md](compliance/runbooks/key-rotation.md) |
| Review who has access | [compliance/runbooks/access-review.md](compliance/runbooks/access-review.md) |
| Incident | [compliance/runbooks/incident-response.md](compliance/runbooks/incident-response.md) |
| Air-gapped test/prod install | [runbook-bootstrap.md](runbook-bootstrap.md) |
| Remove everything (dev) | `CONFIRM=dev CLUSTER=1 make destroy ENV=dev` |

## Glossary

| Term | Meaning |
|---|---|
| **Air-gap** | The servers have no network path to the internet. Everything they need is copied in beforehand (images into Zot, binaries in a bundle) |
| **Artefact** | A built, versioned thing that is deployed: here the solution's container image and OPA bundle |
| **Bundle** | (1) an air-gap bundle: a directory with images, charts and binaries to carry into an air-gapped site (`make airgap-bundle`); (2) an OPA bundle: a tarball of policies and data |
| **Catalog** | The service that records which Iceberg tables exist and where their current metadata is. Here Polaris, with one catalog per layer |
| **CRD** | Custom Resource Definition: a new object type in Kubernetes, installed by an operator (e.g. `Certificate` from cert-manager) |
| **Digest** | `sha256:...`, the hash of an image's content. A reference with a digest always means exactly the same bytes; a tag like `:1.2` can move |
| **Iceberg** | An open table format: data files (Parquet) plus metadata files that list which files form the table in each version (*snapshot*) |
| **Keystore** | (solution) tables that remember every surrogate key ever handed out, so dimension keys stay stable |
| **Lakehouse** | Tables stored as files in object storage, queried with SQL like a database |
| **Mirror** | Copying upstream images and charts into Zot, byte for byte, by digest (`make airgap-mirror`) |
| **Namespace** | A Kubernetes folder for resources; here one per function (`query`, `orchestration`, ...) |
| **NetworkPolicy** | A Kubernetes firewall rule for pods. Here every namespace denies everything by default and allows listed flows |
| **OIDC** | OpenID Connect: the login protocol between Keycloak and the applications; tokens carry the user and the groups |
| **OpenTofu** | The open-source fork of Terraform. It compares code with what exists and applies the difference |
| **Operator** | A controller in the cluster that manages one kind of software (e.g. CloudNativePG creates PostgreSQL clusters) |
| **PKI** | Public key infrastructure: the certificate authorities and the certificates they issue |
| **Plan / apply** | `tofu plan` shows the changes, `tofu apply` makes them. `make plan` / `make deploy` wrap them |
| **PSS** | Pod Security Standards: Kubernetes levels `privileged`, `baseline`, `restricted` for what a pod may do |
| **REST catalog** | The HTTP API of the Iceberg catalog; Trino and the ingestion code use it to find and commit tables |
| **SBOM** | Software bill of materials: the list of packages inside an image |
| **SCD2** | Slowly changing dimension type 2: every change of a member becomes a new row with its own key and a validity period |
| **Stack** | One OpenTofu root project in `stacks/NN-name/`, deployed on its own with its own state |
| **State** | OpenTofu's record of what it created. Here one encrypted state per stack and environment, never inside the cluster |
| **Surrogate key** | A meaningless integer key for a dimension row, used by facts instead of the business key |
| **tfvars** | Files with values for OpenTofu variables, per environment and stack (`environments/<env>/<stack>.tfvars`) |
| **Unseal** | OpenBao starts *sealed* (its data encrypted and unreadable). Unsealing gives it the key shares so it can decrypt. Needed after every OpenBao restart |
| **Zot** | The container registry used as the mirror |
