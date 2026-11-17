# Runbook: patching and upgrades through the version lock

Every image, chart and binary is pinned in `versions.yaml` and resolved to
digests/checksums in `versions.lock.yaml`. Nothing else can run: Kyverno
(`stacks/31-policy`) rejects images that are not from the Zot mirror, not
pinned by digest or tagged `latest` once `policy_mode = "Enforce"`.

## Cycle (connected side, then air-gapped side)

1. **Trigger**: vendor advisory, Trivy finding (`make scan ENV=<env>`), a new
   release, or the regular patch window **[manual: set the cadence]**.
2. Edit `versions.yaml` (tag/version), `make lock` → review the lock diff.
3. Refresh the vulnerability DB: `make trivy-db ENV=<env>` (or bundle/load).
4. `make airgap-mirror ENV=<env> GROUPS=<group>` with
   `SUPPLY_CHAIN_HOOKS=1 VERIFY_SIGNATURES=1 SCAN=1 SBOM=1` (signature
   verification before the image enters Zot, scan + SBOM after) — or
   `make airgap-bundle` → transfer → `make airgap-load`.
5. Gate: `FAIL_ON=CRITICAL make scan ENV=<env> GROUPS=<group>`; record
   accepted risks with a justification and expiry.
6. Solution artefacts: built and pushed by the solution repo, then
   `make sign ENV=<env> REFS="<registry>/boccob/<name>@sha256:…"`.
7. `make plan ENV=test STACK=<stack>` → review → `make deploy ENV=test STACK=<stack>` → `make verify ENV=test`.
8. Same on prod in the change window; `make verify ENV=prod`; keep outputs.
9. Commit `versions.yaml` + `versions.lock.yaml` (+ code changes) together.

## Special cases

- **k3s**: new `k3s` version in `versions.yaml` → `make node-bundle` → upgrade
  servers one by one, then agents (`host-install.sh`, drain first); take an
  etcd snapshot before (`k3s etcd-snapshot save`).
- **OpenBao**: StatefulSet `OnDelete`: standbys first, unseal each, then step-down and the old leader (`runbook-bootstrap.md` §6).
- **PostgreSQL minor**: new `postgresql` image digest → CNPG rolling update (`primaryUpdateStrategy: unsupervised`). Major versions need an import/upgrade plan.
- **CloudNativePG 1.31** removes the in-tree Barman object store used for
  backups: migrate to the Barman Cloud Plugin **before** upgrading the operator.

## Rollback

Revert the commit of `versions.yaml`/`versions.lock.yaml`, the old digests are
still in Zot (registry garbage collection must keep them for a retention
period), `make deploy`. Database schema changes may not be reversible: take a
`make backup` before upgrades of stateful components.
