# Runbook: key and secret rotation

Rotate on a schedule set by the crypto/key-management policy, and immediately
on suspected compromise or when a person with access leaves. **[manual]**
Status: **[verified]** procedures were run on dev, **[static]** not executed.

| Secret | Where it lives | Rotation |
|---|---|---|
| OpenBao unseal key shares | custodians (PGP-encrypted shares) | `bao operator rekey` with a quorum (new shares, new PGP keys); record hand-over **[static]** |
| OpenBao root token | revoked after bootstrap | generate only when needed (`bao operator generate-root`, quorum), revoke after use **[static]** |
| OpenBao encryption key (barrier) | OpenBao | `bao operator rotate` (new key term; old data re-encrypted lazily) **[static]** |
| Cosign signing key (transit `cosign-solution`) | OpenBao transit, not exportable | `bao write -f transit/keys/cosign-solution/rotate`, then `make deploy STACK=31-policy` (all key versions are passed to Kyverno, so existing signatures stay valid); re-sign artefacts; trim old versions with `min_decryption_version` / `min_encryption_version` when all artefacts are re-signed **[static]** |
| PKI issuing CA / root CA | OpenBao `pki_int` / `pki` | see `certificate-rotation.md` |
| S3 user keys (`kv/storage/s3-users/<user>`) | generated in-cluster (`modules/generated-secret`), OpenBao is the source of truth | `bao kv metadata delete kv/storage/s3-users/<user>` + `kubectl -n storage delete secret s3-user-<user>-seed` (new value generated and pushed create-only), force-sync `externalsecret/s3-user-<user>`, `make deploy STACK=12-foundation-services` (provisioning job sets the new key in RustFS), restart consumers **[static]** |
| RustFS root credentials (`kv/storage/rustfs-root`) | generated in-cluster | delete the KV entry and Secret `storage/rustfs-root-seed`, force-sync, redeploy stack 12, restart RustFS **[static]** |
| SSE-S3 master key (`kv/storage/rustfs-sse`) | ESO generated | **do not rotate by deleting**: objects encrypted with the old key become unreadable. Requires a re-encryption plan (copy objects with the new key) — open item **[static]** |
| OIDC client secrets (`kv/identity/oidc-clients/<client>`) | generated in-cluster | delete the KV entry and `identity/oidc-client-<client>-seed`, force-sync `externalsecret/oidc-client-<client>`, redeploy stack 12 (realm job re-imports the client), restart the relying party **[static]** |
| Keycloak admin (`kv/identity/keycloak-admin`) | break-glass | rotate after every use **[manual]** |
| PostgreSQL application credentials (`<cluster>-app`) | CloudNativePG | delete the Secret `<cluster>-app` in `database`; CNPG regenerates it, PushSecret updates OpenBao, consumers' ExternalSecrets refresh; restart consumers **[static]** |
| Off-site S3 credentials (`kv/backup/offsite-s3`) | operator-entered | `bao kv put kv/backup/offsite-s3 access-key=… secret-key=…` after the provider rotated them **[manual]** |
| Registry push password | `~/.boccob/<env>/registry/push-password` + Zot htpasswd | regenerate both (registry-up) **[static]** |
| OpenTofu state passphrase | key custody | change requires re-encrypting all states: OpenTofu `fallback` key provider for one apply per stack, then remove the fallback **[static]** |
| k3s server token / etcd snapshots | servers | `k3s token rotate` (k3s docs for the pinned version) **[static]** |

Generated secrets (`modules/generated-secret`) are pushed to OpenBao
create-only and read back from it: deleting only the Kubernetes Secret does
**not** rotate anything (the OpenBao value is restored). Rotation = delete the
KV entry **and** the `<name>-seed` Secret, then force a sync
(`kubectl -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite`).

After every rotation: `make verify ENV=<env>` and record date, secret, operator.
