# Runbook: bootstrap, air-gap transfer, key custody

Status legend: **[verified]** exercised on the dev cluster in the build
sandbox; **[static]** shellcheck / `tofu validate` only (no test/prod hosts
were available).

## 1. Prerequisites (operator workstation)

podman, skopeo, helm 3.18+, OpenTofu 1.10.x, kubectl, jq, yq (python-yq),
curl, openssl, shellcheck. Optional supply-chain tools: `make tools`
(cosign, trivy, syft; pinned in `versions.lock.yaml`).

`skopeo` is used for mirroring instead of `podman pull/push` because it copies
manifests byte-for-byte (`--preserve-digests`); podman re-compresses layers on
push, which changes digests. Podman remains the container engine.

## 2. dev from scratch [verified]

```
make cluster-up ENV=dev      # registry + mirror of the "cluster" group + k3s node, ~2 min
make airgap-mirror ENV=dev   # remaining images + charts into Zot
make deploy ENV=dev          # 00 -> 10 (+ OpenBao init/unseal) -> 11 -> 12 -> 20 -> 30
make verify ENV=dev
```

Local state in `~/.boccob/dev/` (0700): `kubeconfig`, `pki/registry-ca.{crt,key}`,
`registry/push-password`, `openbao/init.json` (unseal key + root token, dev
only), `tofu/state-passphrase`. Losing this directory means losing the
environment: `CONFIRM=dev CLUSTER=1 make destroy ENV=dev` and start again.

After a host restart: `make cluster-up ENV=dev` (re-creates stale containers
from their volumes, unseals OpenBao) [verified, happened three times during the build].

Sandbox specifics handled automatically in dev only: cgroup v1 host
(`fail-cgroupv1=false`), missing `CAP_SYS_RESOURCE`
(containerd `restrict_oom_score_adj`), absolute kubelet eviction thresholds.

## 3. Air-gap transfer (test/prod)

Connected side:

```
make lock                                    # only when versions.yaml changed
SUPPLY_CHAIN_HOOKS=1 VERIFY_SIGNATURES=1 \
  make airgap-bundle ENV=prod BUNDLE=/media/out/boccob-bundle TAR=1     # [verified with GROUPS=cluster]
make providers-mirror BUNDLE=/media/out/tofu-provider-mirror            # [static]
make node-bundle ENV=prod                                               # [verified: bundle content]
```

Transfer `boccob-bundle.tar` (+ `.sha256`), the provider mirror, the node
bundle and a checkout of this repository at the same commit.

Air-gapped side:

1. Registry host: start Zot exactly like `scripts/cluster/registry-up.sh` does
   (TLS certificate for `registry.<env>.lakehouse.internal`, htpasswd push
   user, anonymous read; the image is `images/zot.tar` in the bundle). Put the
   CA at `~/.boccob/<env>/pki/registry-ca.crt` and the push password at
   `~/.boccob/<env>/registry/push-password`. [static: only the Podman variant ran]
2. `make airgap-load ENV=prod BUNDLE=/media/in/boccob-bundle` — verifies
   SHA256SUMS, that the bundle matches `versions.lock.yaml`, and every digest
   after the push. [verified: load path, digest preserved]
3. `make airgap-check ENV=prod`; `make scan ENV=prod FAIL_ON=CRITICAL`,
   `make sbom ENV=prod` (Trivy needs its vulnerability DB mirrored:
   `TRIVY_DB_REPOSITORY`). [verified in dev: scan + SBOM of one image]
4. Place the provider mirror at `~/.cache/boccob/tofu-provider-mirror`
   (`scripts/tofu.sh` then uses it instead of registry.opentofu.org).

Signature verification: `make verify-signatures` implements the policy in
`scripts/supply-chain/signature-policy.yaml`. Keyless verification needs the
Sigstore TUF root (`tuf-repo-cdn.sigstore.dev`), which the build sandbox
blocks, so the identities in that file are **unverified** — confirm each one
on a connected workstation before relying on it.

## 4. k3s on hosts (test/prod) [static]

Hosts: cgroup v2, time sync, DNS for `registry.<env>…`, `k3s.<env>…` (fixed
registration address: VIP/LB/round-robin over the three servers) and
`*.<env>.lakehouse.internal` (ingress). Inventory in `environments/<env>/env.sh`.

```
make cluster-up ENV=prod     # scripts/cluster/hosts-up.sh over SSH, or by hand on each node:
  ./host-install.sh server --cluster-init                                    # first server
  K3S_TOKEN_FILE=/root/k3s-token ./host-install.sh server --join https://k3s.prod.lakehouse.internal:6443
  K3S_TOKEN_FILE=/root/k3s-token ./host-install.sh agent  --join https://k3s.prod.lakehouse.internal:6443
```

`host-install.sh` writes the same hardened configuration the dev node runs
with (`scripts/lib/k3s-config.sh`), installs the k3s binary and the air-gap
images tarball and runs the upstream installer with
`INSTALL_K3S_SKIP_DOWNLOAD=true`. Set `storage_class` in the tfvars to the
site CSI class (local-path is node-local and not suitable for HA data).
Then: `make deploy ENV=prod`, `make verify ENV=prod` (set `INGRESS_IP`).

## 5. OpenBao key custody (test/prod)

Initialisation (`scripts/openbao/init.sh`, run by `make deploy` after stack 10):

- Shamir 5 shares / threshold 3 (`OPENBAO_KEY_SHARES`, `OPENBAO_KEY_THRESHOLD`).
- `OPENBAO_PGP_KEYS=c1.asc,c2.asc,c3.asc,c4.asc,c5.asc` — one public key per
  custodian — and `OPENBAO_ROOT_TOKEN_PGP_KEY=security-officer.asc`.
  OpenBao encrypts every share and the root token itself; the script refuses
  to store plaintext keys outside dev. `~/.boccob/<env>/openbao/init.json`
  then contains ciphertext only. [static: PGP path not executed; plaintext path verified in dev]
- Hand each custodian their encrypted share (`keys_base64[i]`), record the
  hand-over, then remove `init.json` from the workstation and keep one sealed
  copy in the safe.
- Custodians: five named people from at least two organisational units; a
  share is decrypted only on the custodian's own device
  (`base64 -d | gpg --decrypt`).

Unseal (after every OpenBao pod restart, each member separately):
`make openbao-unseal ENV=prod` on a terminal — three custodians enter their
share at the hidden prompt; shares are sent on stdin to the API over TLS and
never written to disk. Consider auto-unseal (PKCS#11 HSM or a transit seal in
a separate OpenBao) if unattended restarts are required; that is a change in
`modules/openbao` (`seal` stanza) and replaces the Shamir procedure.

Root token: needed once for stack `11-foundation-pki` (and until OIDC login is
wired). Procedure: security officer decrypts it, exports `BAO_TOKEN` for
`make deploy ENV=prod STACK=11-foundation-pki`, then
`bao token revoke -self`. Later administrative runs use a short-lived token
of an operator in the Keycloak group `platform-admin` (policy `platform-admin`
exists; the OIDC auth method for people is **not configured yet** — see open
items) or a new root token generated with `bao operator generate-root`
(needs three custodians).

OpenTofu state passphrase (`TOFU_STATE_PASSPHRASE`, >= 32 characters): held in
the same custody store, two sealed copies. Without it the state Secrets cannot
be read; with a lost passphrase the stacks must be re-imported.

Other material: bootstrap CA key (Secret `platform-system/bootstrap-ca`, part
of etcd snapshots), registry CA key (registry host), k3s server token and
etcd snapshot encryption — covered by the backup & DR work package.

Break-glass accounts: Keycloak `bootstrap-admin` (`kv/identity/keycloak-admin`),
RustFS root (`kv/storage/rustfs-root`). Create personal admin accounts, then
rotate these and restrict the KV paths.

## 6. Day 2

| Task | How |
|---|---|
| Upgrade a component | edit `versions.yaml` -> `make lock` -> `make airgap-mirror` (or bundle/load) -> `make deploy STACK=..` -> `make verify` |
| OpenBao upgrade | update strategy is `OnDelete`: delete standby pods one by one (unseal each), then `bao operator step-down` and the old leader |
| Rotate a generated secret | `kubectl -n <ns> delete secret <name>`; ESO generates and pushes a new value; restart consumers (Keycloak clients: redeploy stack 12 so the realm Job re-imports) |
| Certificates | renewed by cert-manager (90 d lifetime, renewal at 60 d); issuing CA 5 y, root 10 y — rotate with a new `pki_int` issuer before expiry |
| Stuck state lock | `kubectl -n tofu-state get lease`; after confirming no run is active: `scripts/tofu.sh <env> <stack> force-unlock <id>` |
| Tear down | `CONFIRM=<env> make destroy ENV=<env> [STACK=..]` |

## 7. Open items

- HA profile (3-node raft, distributed RustFS, 3-instance PostgreSQL,
  2 Keycloak pods) has not been deployed anywhere; multi-node webhook and
  NetworkPolicy paths (`cluster_cidrs`) need a test on real hosts.
- OpenBao OIDC login for people (Keycloak client `openbao` exists) and
  revocation of the initial root token.
- Per-namespace SecretStores instead of cluster-wide KV access.
- Keycloak: optimised image (read-only root filesystem), user federation.
- Zot on the registry host for test/prod as a systemd/quadlet unit; registry
  backup; Trivy DB mirroring.
- Kyverno admission (digest pinning, signature verification), backups of
  PostgreSQL / OpenBao raft snapshots / RustFS replication: ops work package.
