# 11-foundation-pki

Needs an initialised, unsealed OpenBao (`STACK_NEEDS_OPENBAO=1`).

- OpenBao baseline (`modules/openbao-config`): KV v2 `kv/`, kubernetes auth,
  root + issuing CA, policies and roles
- ConfigMap `platform-system/platform-ca` (internal trust bundle)
- ClusterIssuer `openbao-pki` (cert-manager -> `pki_int/sign/platform`,
  authenticated with a bound ServiceAccount token)
- ClusterSecretStores `openbao` (read) and `openbao-push` (write, used for
  generated secrets), usable from namespaces labelled
  `boccob.io/secrets-access=true`
