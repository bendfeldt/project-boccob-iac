# 10-foundation-secrets

- `bootstrap-selfsigned` / `bootstrap-ca` ClusterIssuers (cert-manager CA used
  only for OpenBao's listener certificate)
- namespace `secrets` with the security baseline
- OpenBao (raft, TLS, declarative audit devices), created sealed

Post-apply hook: `scripts/openbao/init.sh <env>` (init, unseal, raft join).
