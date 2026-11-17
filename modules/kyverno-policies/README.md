# kyverno-policies

The Boccob policy set as a local Helm chart (`chart/`), so that the custom
resources can be applied in the same stack as Kyverno (no plan-time CRD lookup)
and do not bloat the OpenTofu state. Inputs: registry host, `mode`
(Audit|Enforce), `enforce_label`, `failure_policy`, `policies` on/off,
`signature_public_keys` (+ globs, mode), `keyless_policies`, `exceptions`
(namespaces, name prefixes, justification). See stack 31-policy README.
`helm template chart` renders the policies standalone for review.
