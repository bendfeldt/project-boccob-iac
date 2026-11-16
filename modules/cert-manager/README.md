# cert-manager

Installs cert-manager (chart + CRDs) from the Zot mirror with digest-pinned
images. Issuers are **not** created here (CRDs must exist before a stack can
plan them): see `stacks/10-foundation-secrets` (bootstrap CA) and
`stacks/11-foundation-pki` (OpenBao PKI ClusterIssuer `openbao-pki`).

Leader election leases are kept in the install namespace (`platform-system`)
instead of `kube-system`.
