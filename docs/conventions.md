# Conventions for contributors (data-plane and ops work packages)

Everything below is exercised by the foundation layer on the running dev
cluster; copy the patterns from `stacks/12-foundation-services`.

## 0. Ground rules

- OpenTofu is only run through `scripts/tofu.sh` (via `make deploy|plan ENV=.. STACK=..`).
- No image or chart reference outside `versions.yaml`; no internet at deploy time.
- No secret value in git, tfvars, tofu outputs, tofu state or logs.
- Every namespace through `modules/namespace-baseline` (default deny, PSS `restricted`).
- TLS everywhere, certificates from ClusterIssuer `openbao-pki`.
- `make lint` and `make verify ENV=dev` must pass before you commit.
- Dev is small: requests of a few 10m CPU / 100 MiB; every heavy optional piece gets an on/off variable.

Dev cluster access:

```
export KUBECONFIG=/root/.boccob/dev/kubeconfig
make cluster-up ENV=dev     # idempotent; also recovers after a host restart and unseals OpenBao (dev)
```

Hosts (in /etc/hosts on the dev machine, published on 127.0.0.1:443):
`keycloak|openbao|s3|s3-console|trino|polaris|dagster|grafana.dev.lakehouse.internal`.
Registry: `registry.dev.lakehouse.internal:5000` (anonymous pull, authenticated push).

## 1. Well-known names (`local.platform` in `stacks/_shared/common.tf`)

| What | Value |
|---|---|
| ClusterIssuer | `openbao-pki` |
| ClusterSecretStore read / write | `openbao` / `openbao-push` |
| KV v2 mount, path layout | `kv`, `kv/<namespace>/<name>` |
| CA bundle ConfigMap (key `ca.crt`) | `platform-ca` (in every baseline namespace that sets `ca_bundle_pem`) |
| OpenBao (in-cluster) | `https://openbao.secrets.svc:8200` |
| S3 endpoint (in-cluster), region | `https://rustfs-svc.storage.svc:9000`, `us-east-1`, path-style |
| OIDC issuer | `https://keycloak.<base_domain>/realms/lakehouse` (same URL inside and outside the cluster) |
| PostgreSQL host of cluster `<name>` | `<name>-rw.database.svc:5432` (`sslmode=verify-full`) |
| Kubernetes audit log on servers | `/var/log/kubernetes/audit/audit.log` (JSON) |
| OpenBao audit log | pod stdout (JSON lines with `"type":"request"/"response"`) and `/openbao/audit/audit.log` |
| Keycloak audit events | pod stdout, logger `org.keycloak.events` |

Certificates are only issued for FQDNs under `<base_domain>`, `*.svc`,
`*.svc.cluster.local`: always address services as `<svc>.<namespace>.svc`
(bare `<svc>` or `<svc>.<namespace>` SANs are rejected by the PKI role).

## 2. Add a module

`modules/<component>/` with `main.tf`, `variables.tf` (every variable described
and typed), `outputs.tf`, `versions.tf` (providers with `>=` constraints; exact
pins live in the stacks), `README.md` with a usage example.

- A module never reads `versions.lock.yaml`; it takes `image` / `chart`
  objects (`module.versions.images["x"]`, `module.versions.charts["x"]`).
- Sizing through variables with dev-sized defaults; an `ha`/`replicas` variable
  switches PDBs, anti-affinity / topology spread.
- Pod security: non-root, `seccompProfile: RuntimeDefault`, drop ALL
  capabilities, read-only root filesystem (document any exception in the README).
  With `kubernetes_deployment_v1`/`kubernetes_job_v1` set
  `run_as_non_root = true` in the **container** security context too (the
  provider otherwise sends `false`, which PSS `restricted` rejects).
- Helm charts: `repository = var.chart.repository` (`oci://<zot>/charts`),
  images via values; where a chart only has `tag`, pass `image.tag_digest`
  (`<tag>@sha256:...`) to keep the digest pin. Check with `helm template`.

## 3. Add a stack

```
stacks/NN-name/
  _common.tf -> ../_shared/common.tf     (symlink: backend, common variables, providers, module.versions, local.platform)
  versions.tf                            (required_version + exact provider pins; copy from an existing stack)
  main.tf  variables.tf  outputs.tf  README.md
  stack.env                              (optional: STACK_NEEDS_OPENBAO=1, STACK_POST_APPLY=scripts/x.sh)
environments/<env>/NN-name.tfvars        (optional sizing per environment)
```

- `make deploy` applies `stacks/[0-9]*` in lexical order; each stack has its
  own encrypted state (`tfstate-default-NN-name` in namespace `tofu-state`).
- Custom resources of a CRD must live in a **later** stack than the operator
  that installs the CRD (`kubernetes_manifest` plans against the live API).
- Do not read other stacks' state. Use the well-known names, data sources
  (e.g. the `platform-ca` ConfigMap) or variables.
- `STACK_NEEDS_OPENBAO=1` gives the stack a configured `vault` provider
  (`provider "vault" { skip_child_token = true }`): port-forward, CA and token
  are handled by `scripts/tofu.sh`.
- Keep states small (see architecture.md, "OpenTofu state"); split
  `20-data-plane` into several stacks if needed.
- Commit the `.terraform.lock.hcl` of the stack.

## 4. Add a mirrored image or chart

1. Add the entry to `versions.yaml` (`images:` with `source`, `tag`, `groups`;
   `charts:` with `repo` (https or oci), `name`, `version`, `groups`).
2. `make lock` (resolves the linux/amd64 digest / chart sha256 into `versions.lock.yaml`).
3. `make airgap-mirror ENV=dev GROUPS=<group>` and `make airgap-check ENV=dev`.
4. Reference it: `module.versions.images["<key>"].ref` (or `.repository` /
   `.tag_digest` / `.registry` + `.repository_path` for charts),
   `module.versions.charts["<key>"]`.

Charts that pull extra images (sidecars, init containers, test hooks): list
**all** of them (`helm template ... | grep image:`), and point every one at the
mirror through chart values.

Solution-repo artefacts (Dagster code-location image, OPA bundle) are pushed to
`<registry>/boccob/<name>` by the solution repo and consumed through variables
(image ref with digest, bundle ref) — they are not in `versions.yaml`.
Push credentials (dev): user `mirror`, password file
`~/.boccob/dev/registry/push-password`, CA `~/.boccob/dev/pki/registry-ca.crt`.

Sandbox note: container registries `docker.io`, `quay.io`, `ghcr.io`,
`registry.k8s.io` are reachable from the build machine; other registries
(e.g. `reg.kyverno.io`, `cgr.dev`) may need an allowlist entry — prefer the
ghcr.io location of an image.

## 5. Add a secret

Generated credential (preferred):

```hcl
module "x_credentials" {
  source    = "../../modules/generated-secret"
  name      = "x-credentials"                 # K8s Secret in the namespace
  namespace = module.ns_x.name                # baseline with secrets_access = true
  kv_path   = "<namespace>/x-credentials"     # -> kv/<namespace>/x-credentials
  keys      = ["password"]
  literals  = { username = "x" }
}
```

Consume a secret that lives in OpenBao (other namespace, or entered by an operator):

```hcl
module "x_secret" {
  source    = "../../modules/external-secret"
  name      = "x-secret"
  namespace = module.ns_x.name                # secrets_access = true
  kv_path   = "identity/oidc-clients/trino"
  # template = { "config.properties" = "secret={{ .password }}" }   # optional reshaping
}
```

Operator-supplied secrets (licences, external credentials) are written with
`bao kv put kv/<namespace>/<name> key=value` by an authorised person and
consumed with `modules/external-secret`. Never add them to tfvars.

Workloads that talk to OpenBao directly need an OpenBao policy + kubernetes
auth role in their own stack (vault provider):

```hcl
resource "vault_policy" "x" {
  name   = "x"
  policy = "path \"kv/data/x/*\" { capabilities = [\"read\"] }"
}
resource "vault_kubernetes_auth_backend_role" "x" {
  backend                          = "kubernetes"
  role_name                        = "x"
  bound_service_account_names      = ["x"]
  bound_service_account_namespaces = ["x-namespace"]
  token_policies                   = [vault_policy.x.name]
  token_ttl                        = 600
}
```

and the namespace must be in `openbao_client_namespaces`
(`environments/<env>/10-foundation-secrets.tfvars`; the default already lists
identity, storage, database, catalog, query, orchestration, observability).

Known limitation: the two ClusterSecretStores can read/write the whole `kv/`
mount for any namespace labelled `boccob.io/secrets-access=true`. Tightening
to per-namespace `SecretStore`s with per-namespace OpenBao roles is an open
hardening item.

## 6. Add a database

```hcl
module "polaris_db" {
  source    = "../../modules/postgres-cluster"
  name      = "polaris-db"
  namespace = local.platform.namespaces.database
  image     = module.versions.images["postgresql"].ref
  instances = var.ha ? 3 : 1
  database  = "polaris"
}
module "polaris_db_credentials" {
  source    = "../../modules/external-secret"
  name      = "polaris-db"
  namespace = module.ns_catalog.name
  kv_path   = module.polaris_db.kv_path       # username, password, dbname, port
}
```

- Host `module.polaris_db.host` (`polaris-db-rw.database.svc`), port 5432,
  TLS required: `sslmode=verify-full`, `sslrootcert` = mounted `platform-ca`.
- Network: the client namespace needs an egress rule to `database:5432`, and
  must be listed in `postgres_client_namespaces`
  (`environments/<env>/12-foundation-services.tfvars`; default: identity,
  catalog, orchestration, observability).
- Backups: pass `backup = { destination_path = "s3://platform-backup/postgres/<name>", endpoint_url = local.platform.s3_url, credentials_secret = "<secret with access_key_id/secret_access_key>" }`
  (S3 user `platform-backup` exists: `kv/storage/s3-users/platform-backup`,
  properties `access-key` / `secret-key` — map them with an `external-secret` template).

## 7. Add a bucket or an S3 user

In `environments/<env>/12-foundation-services.tfvars` (merged over the built-ins):

```hcl
buckets  = { "lakehouse-scratch" = { versioning = false } }
s3_users = { "trino" = { read_write_buckets = ["lakehouse-clean"], read_only_buckets = ["lakehouse-raw"] } }
```

`make deploy ENV=<env> STACK=12-foundation-services` re-runs the idempotent
provisioning Job. Credentials: `kv/storage/s3-users/<name>` (`access-key`,
`secret-key`). Built-in users: `lakehouse-catalog` (rw on the four layer
buckets), `lakehouse-ingest` (rw raw), `platform-backup`, `platform-logs`.
S3 clients: endpoint `https://rustfs-svc.storage.svc:9000`, path-style access,
region `us-east-1`, CA from `platform-ca`; the namespace must be in
`s3_client_namespaces` (default: database, secrets, catalog, query,
orchestration, observability) and have an egress rule to `storage:9000`.
All contract buckets have versioning enabled.

## 8. Add an OIDC client

In `environments/<env>/12-foundation-services.tfvars` (merged over the built-in
clients trino, polaris, dagster, grafana, openbao):

```hcl
oidc_clients = {
  superset = {
    name          = "Superset"
    redirect_uris = ["https://superset.dev.lakehouse.internal/oauth-authorized/keycloak"]
    # service_account = true, direct_access_grants = false, pkce_required = false
  }
}
```

Redeploy stack 12. The secret is generated and stored at
`kv/identity/oidc-clients/<client id>` with properties `client-id`,
`client-secret`, `issuer`. Tokens carry a `groups` claim (group names:
`platform-admin`, `data-engineer`, `analyst`, `pii-reader`, `auditor`) and
realm roles in `realm_access.roles`; the audience contains the client id.
Changing a client definition recreates that client in Keycloak.
Relying parties must reach the issuer through its public hostname: set
`allow_ingress_hosts = true` in their namespace baseline and trust `platform-ca`.
Users are not managed here (create them in Keycloak or federate a directory);
for tests: `kcadm.sh` inside the Keycloak pod with the credentials at
`kv/identity/keycloak-admin`.

## 9. Add an ingress host

```hcl
module "ingress_trino" {
  source       = "../../modules/ingress-host"
  name         = "trino"
  namespace    = module.ns_query.name
  host         = "trino.${var.base_domain}"
  service_name = "trino"
  service_port = 8443
  backend_tls  = { server_name = "trino.query.svc" }   # omit only for plain-HTTP backends
}
```

Plus `ingress_controller_ports = [8443]` and `ca_bundle_pem` in the namespace
baseline. The certificate comes from `openbao-pki`. dev: add the short name to
`DEV_INGRESS_HOSTS` in `environments/dev/env.sh` if it is not listed and run
`make cluster-up ENV=dev` (updates /etc/hosts). test/prod: DNS record
`<svc>.<base_domain>` -> ingress address. Only one module instance may own the
backend-TLS annotations of a Service (see `ingress_s3` / `ingress_s3_console`).

## 10. Add a namespace and NetworkPolicy allows

```hcl
data "kubernetes_config_map_v1" "platform_ca" {
  metadata {
    name      = local.platform.ca_configmap
    namespace = local.platform.namespaces.platform
  }
}

module "ns_query" {
  source         = "../../modules/namespace-baseline"
  name           = local.platform.namespaces.query
  labels         = local.common_labels
  secrets_access = true
  ca_bundle_pem  = data.kubernetes_config_map_v1.platform_ca.data["ca.crt"]

  allow_kube_api           = false          # true only for operators/controllers
  allow_ingress_hosts      = true           # may call https://keycloak.<base_domain> etc.
  ingress_controller_ports = [8443]         # Traefik -> pods
  ingress_rules = [{ name = "metrics", from_namespaces = ["observability"], ports = [8443] }]
  egress_rules = [
    { name = "polaris", to_namespaces = ["catalog"], ports = [8181] },
    { name = "s3", to_namespaces = ["storage"], ports = [9000] },
  ]
  resource_quota = { "requests.memory" = "4Gi", "limits.memory" = "8Gi" }
}
```

A cross-namespace flow needs both ends: egress in the client namespace
**and** ingress in the server namespace. The foundation servers are opened with
tfvars of their stacks: `openbao_client_namespaces` (stack 10),
`postgres_client_namespaces`, `s3_client_namespaces`,
`keycloak_client_namespaces`, `metrics_namespaces` (stack 12).
Use `module.ns_x.name` for everything placed in the namespace so resources are
created after the policies. Metrics ports already opened for
`metrics_namespaces` (default `observability`): CNPG 9187, RustFS 9000,
Keycloak 9000 (HTTPS). `platform-system`, `secrets` and `kube-system` are not
opened for scraping yet — the ops package should request the ports it needs
(variables in stacks 00/10).

## 11. Scripts

Bash, `set -euo pipefail` through `scripts/lib/common.sh`, shellcheck-clean
(`make lint`), a Makefile target for every entry point. Use `load_env`,
`log/warn/die/step`, `lock_q`, `image_zot_ref`, `wait_for`,
`write_secret_file`. Secrets never on a command line (stdin / files 0600).
