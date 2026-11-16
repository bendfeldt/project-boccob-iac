# openbao-config

Baseline OpenBao configuration through the `hashicorp/vault` provider
(API compatible with OpenBao):

- KV v2 at `kv/` — layout `kv/<namespace>/<name>`
- Kubernetes auth at `auth/kubernetes`
- PKI: root CA `pki/` (EC P-384, key generated inside OpenBao) and issuing CA
  `pki_int/` with role `platform`
- policies `cert-manager`, `external-secrets-read`, `external-secrets-push`,
  `platform-admin`, `auditor`
- kubernetes auth roles `cert-manager`, `external-secrets`, `external-secrets-push`

The provider is configured by the calling stack from `VAULT_ADDR`,
`VAULT_CACERT` and `VAULT_TOKEN`, which `scripts/tofu.sh` exports for stacks
with `STACK_NEEDS_OPENBAO=1` (port-forward to the active member).

To add a workload role or policy from another stack use the `vault_policy` /
`vault_kubernetes_auth_backend_role` resources directly (see
docs/conventions.md, "Secrets").
