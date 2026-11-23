# 11-foundation-pki

Needs an initialised, unsealed OpenBao (`STACK_NEEDS_OPENBAO=1`).

- OpenBao baseline (`modules/openbao-config`): KV v2 `kv/`, kubernetes auth,
  root + issuing CA, policies and roles
- ConfigMap `platform-system/platform-ca` (internal trust bundle)
- ClusterIssuer `openbao-pki` (cert-manager -> `pki_int/sign/platform`,
  authenticated with a bound ServiceAccount token)
- per-namespace OpenBao roles `eso-<ns>-read` (`kv/<ns>/*` plus granted
  cross-namespace paths) and `eso-<ns>-push` (`kv/<ns>/*` only), one entry per
  namespace in `namespace_secret_stores`; the namespaces' own SecretStores
  `openbao` / `openbao-push` (created by `modules/namespace-baseline`) log in with
  them (docs/conventions.md, "Add a secret"). The old cluster-wide
  ClusterSecretStores exist only while `legacy_cluster_store_namespaces` is
  non-empty (default: empty, not created)
