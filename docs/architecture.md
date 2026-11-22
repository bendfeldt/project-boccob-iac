# Architecture (IaC repository, foundation layer)

## Layers and stacks

```
 versions.yaml -> make lock -> versions.lock.yaml  (image digests per arch, chart + binary sha256)
        |
        v
 Zot registry (images + charts as OCI)  <- make airgap-mirror | airgap-bundle -> airgap-load
        |
        v   k3s nodes pull ONLY from Zot (registries.yaml, no upstream fallback)
 +--------------------------------------------------------------------------------+
 | 00-bootstrap            platform-system: cert-manager, External Secrets,       |
 |                         CloudNativePG operator; hardened Traefik; CoreDNS      |
 | 10-foundation-secrets   bootstrap CA, namespace secrets, OpenBao (sealed)      |
 |      -> scripts/openbao/init.sh (init, unseal, raft join)                      |
 | 11-foundation-pki       OpenBao: KV v2, kubernetes auth, root + issuing CA;    |
 |                         ClusterIssuer openbao-pki; per-namespace ESO roles     |
 | 12-foundation-services  database ns (+ backup credentials), storage (RustFS +  |
 |                         buckets, S3 users), ingress hosts s3/openbao           |
 | 13-identity             identity: Keycloak realm lakehouse, OIDC clients;      |
 |                         keycloak-db (CNPG cluster in ns database)              |
 | 20-catalog              catalog: Polaris (+ polaris-db), catalogs, principals  |
 | 21-query                query: Trino + OPA (policy bundle from Zot)            |
 | 22-orchestration        orchestration: Dagster (+ dagster-db), oauth2-proxy    |
 | 30-observability        Prometheus/Alertmanager, Loki (tenants platform/audit),|
 |                         OTel log collector, audit WORM archive, Grafana        |
 | 31-policy               Kyverno + policy set, cosign key (OpenBao transit)     |
 | 32-backup               OpenBao snapshots, S3 retention, off-site copy         |
 +--------------------------------------------------------------------------------+
```

Why several foundation stacks: (1) custom resources can only be planned once
their CRDs exist, so operators come first; (2) OpenBao must be initialised and
unsealed by people (key custody) between "installed" and "configured".
Stacks never read each other's state; they share **well-known names**
(`stacks/_shared/common.tf`, `local.platform`).

## Cluster

| | dev | test / prod |
|---|---|---|
| Kubernetes | k3s server in one Podman container (`boccob-dev-server-0`) | k3s on hosts: 3 servers (embedded etcd) + agents |
| Install | `scripts/cluster/dev-up.sh` | node bundle + `scripts/cluster/host-install.sh` (air-gap: binary + images tarball) |
| Registry | Zot Podman container on the same podman network | Zot on a registry host (same config), reachable as `registry.<env>.lakehouse.internal:5000` |
| Config | one renderer for all: `scripts/lib/k3s-config.sh` | same |
| Architecture | the machine's (`uname -m`), or the podman machine's on macOS: amd64 or arm64 | `CLUSTER_ARCH` in `env.sh` (default amd64); one per cluster |
| Container host | Linux: podman as root on the machine; macOS: a rootful `podman machine` VM (`CLUSTER_RUNTIME=podman-machine`) | the nodes |

Hardening (k3s CIS guide): secrets encryption at rest, `protect-kernel-defaults`,
API audit policy + JSON audit log (`/var/log/kubernetes/audit/audit.log` on
servers), Pod Security admission (cluster default `baseline`, platform
namespaces `restricted`), EventRateLimit, TLS >= 1.2 with AEAD suites, no cloud
controller, no fallback to upstream registries, kubelet PID limit.
Kept on purpose: Traefik, ServiceLB (ingress entry), local-path (dev storage;
test/prod should set `storage_class` to their CSI class), metrics-server (HPA).

Ingress: the Traefik bundled with k3s, hardened through `HelmChartConfig`
(HTTPS redirect, strict SNI, no dashboard, no cross-namespace references, JSON
access log). Chosen over a separate controller because it ships in the k3s
air-gap image set and is upgraded with k3s. Backends speak TLS; Traefik
verifies them (`ServersTransport`) against the platform CA.

## Trust and secrets

```
 bootstrap CA (cert-manager CA issuer) ---> OpenBao listener certificate only
 OpenBao pki (root, EC P-384, key never leaves OpenBao)
     +-- pki_int (issuing CA) --- role "platform" ---> ClusterIssuer openbao-pki
                                                        -> every pod / ingress certificate
 ConfigMap platform-ca (root + issuing + bootstrap CA) in every platform namespace

 secret values: generated in-cluster (ESO Password generator) or by operators
     -> Kubernetes Secret -> PushSecret -> OpenBao kv/<namespace>/<name>
     -> ExternalSecret (SecretStore openbao of the consuming namespace; OpenBao role
        eso-<ns>-read: kv/<ns>/* + granted cross-namespace paths) -> Secret
```

- cert-manager and ESO authenticate to OpenBao with bound ServiceAccount
  tokens (kubernetes auth); there is no static OpenBao token in the cluster.
- No secret value in git, tfvars, tofu outputs or tofu state. State is also
  encrypted client-side (see below).
- OpenBao audit devices are declared in the server configuration (stdout +
  file on a dedicated volume) and cannot be disabled through the API.

## OpenTofu state

One state per stack and environment, never inside the cluster it manages, plus
OpenTofu state/plan encryption (AES-GCM, PBKDF2 key, `enforced`; the passphrase
is part of key custody, see the runbook):

| | backend | where | lock |
|---|---|---|---|
| dev | `local` | `~/.boccob/dev/tofu/state/<stack>.tfstate` | lock file next to it |
| test/prod | `s3` | bucket outside the cluster and the site (`TOFU_STATE_S3_*`), key `<prefix>/<env>/<stack>.tfstate` | `use_lockfile` (`.tflock` object) |

`scripts/tofu.sh` selects the backend from `TOFU_BACKEND` (`environments/<env>/env.sh`)
by writing the stack's `backend_override.tf` (gitignored; one environment at a
time per checkout). A working directory initialised with another backend type
is migrated automatically on the next run (`tofu init -migrate-state`; the old
copy is kept). The state survives the loss of the cluster or the site (DR
runbook, scenario D) and needs only the state passphrase. `make verify` checks
that every stack's stored state is encrypted.

## Namespaces and network

Every namespace is created by `modules/namespace-baseline`: PSS labels,
default-deny for ingress and egress, DNS allowed, explicit rules for the
rest, optional quota/limit range, the `platform-ca` ConfigMap. Enforcement is
done by the k3s embedded network policy controller (verified by
`make verify`).

| Namespace | Owner stack | Content |
|---|---|---|
| `platform-system` | 00 | cert-manager, External Secrets, CloudNativePG operator |
| `secrets` | 10 | OpenBao |
| `database` | 12 | all CloudNativePG clusters |
| `storage` | 12 | RustFS |
| `identity` | 13 | Keycloak |
| `catalog`, `query`, `orchestration` | 20, 21, 22 | Polaris, Trino + OPA, Dagster (docs/data-plane.md) |
| `observability` | 30 | Prometheus, Alertmanager, Loki, Grafana, audit archive |
| `observability-agent` | 30 | OTel log collector DaemonSet (PSS privileged: read-only hostPath) |
| `kyverno` | 31 | Kyverno, PolicyExceptions |
| `backup` | 32 | backup CronJobs (OpenBao snapshot, off-site copy) |

The contract namespace `registry` is not used: Zot must exist before the
cluster can pull anything, so it runs outside the cluster (Podman container in
dev, registry host in test/prod).

## HA profile (`ha = true`, test/prod tfvars)

| Component | dev | HA |
|---|---|---|
| OpenBao | 1 raft member | 3 raft members, PDB |
| PostgreSQL | 1 instance | 3 instances, required anti-affinity, PDB |
| RustFS | 1 pod / 1 volume | distributed, 4 nodes x N drives, PDB |
| Keycloak | 1 pod (local cache) | 2 pods (Infinispan via jdbc-ping), topology spread, PDB |
| cert-manager / ESO / CNPG operator | 1 | 2 with leader election, PDBs |
| Traefik | 1 | 2, PDB |

The HA profile is validated statically (`tofu validate`) only; it has not been
deployed in the build sandbox.

## Component facts verified upstream

- RustFS 1.0.6: Apache-2.0; chart from `charts.rustfs.com` (source
  `rustfs/rustfs/helm/rustfs`); image `docker.io/rustfs/rustfs`; versioning,
  object lock, bucket and site replication, lifecycle, IAM policies listed as
  available in the upstream README; CLI `rustfs/rc`. Versioning was exercised
  here through the S3 API (`GetBucketVersioning` = Enabled).
- OpenBao 2.7.3: declarative `audit` stanzas; API audit creation is disabled by
  default upstream.
- CloudNativePG 1.30.2: in-tree Barman object store still present in the CRD
  (used by `modules/postgres-cluster` with the `system` operand image).
- Keycloak 26.8.2, External Secrets 2.15.0, cert-manager 1.21.3, k3s 1.37.2.
