# 31-policy

Kyverno (namespace `kyverno`) and the policy set
(`modules/kyverno-policies`, CEL `ValidatingPolicy` / `ImageValidatingPolicy`):

| Policy | Rule |
|---|---|
| restrict-image-registries | images only from `<registry_host>/` (Zot mirror) |
| require-image-digest | `@sha256:` digest required |
| disallow-latest-tag | no `:latest`, no untagged references |
| require-run-as-non-root | `runAsNonRoot: true` (pod or container) |
| require-read-only-root-filesystem | `readOnlyRootFilesystem: true` |
| require-requests-limits | CPU + memory requests, memory limit |
| verify-solution-image-signatures | `<registry>/boccob/*` signed with the cosign key in OpenBao transit (`cosign-solution`, not exportable; all key versions trusted) |

Mode: `policy_mode = "Audit"` (default; results in `kubectl get policyreport -A`)
or `"Enforce"`. Namespaces labelled `boccob.io/policy-enforce=true` are
enforced already in Audit mode (each policy has an `-enforce` twin that matches
only those namespaces) — roll out namespace by namespace; `make verify` uses
this to prove blocking. `failurePolicy` Ignore in dev, Fail with `ha`.
Excluded: `kube-system` (k3s system pods use upstream names through the
registries.yaml mirror).

Exceptions (`builtin_exceptions` in main.tf, more via `policy_exceptions`),
each with `boccob.io/justification`: Keycloak writable rootfs (upstream image
build step), RustFS chart init container without resources, log collector as
uid 0. Verified on dev: signed artefact admitted, unsigned denied; non-compliant
pod denied in an enforced namespace; exceptions suppress the reported failures.

Upstream keyless verification at admission (`keyless_policies`) needs the
signatures mirrored next to the images and a Sigstore trust root; by default
upstream signatures are verified at mirror time (`make verify-signatures`).
