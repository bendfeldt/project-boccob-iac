# namespace-baseline

Creates (or adopts) a namespace with the platform security baseline:

| Control | Implementation |
|---|---|
| Pod Security Standards | `pod-security.kubernetes.io/enforce=<level>` (default `restricted`), audit+warn always `restricted` |
| Network segmentation | `default-deny` NetworkPolicy for ingress **and** egress, plus explicit allows |
| Resource governance | optional `ResourceQuota`, `LimitRange` with small container defaults |
| Trust | optional `platform-ca` ConfigMap (`ca.crt`) with the internal CA bundle |
| Secrets access | `secrets_access = true`: SecretStores `openbao` (read) and `openbao-push` (write) in the namespace, with ServiceAccounts `eso-read` / `eso-push` and the OpenBao roles `eso-<ns>-read` / `eso-<ns>-push` of stack 11 (label `boccob.io/secrets-access=true`) |

Built-in allows (toggle with variables): DNS egress, same-namespace traffic,
Kubernetes API egress (`allow_kube_api`), ingress from Traefik
(`ingress_controller_ports`). Everything else goes through
`ingress_rules` / `egress_rules`.

```hcl
module "ns_query" {
  source         = "../../modules/namespace-baseline"
  name           = "query"
  secrets_access = true
  ca_bundle_pem  = local.platform_ca_pem

  ingress_controller_ports = [8443]
  egress_rules = [
    { name = "polaris", to_namespaces = ["catalog"], ports = [8181] },
    { name = "rustfs", to_namespaces = ["storage"], ports = [9000] },
    { name = "keycloak", to_namespaces = ["identity"], ports = [8443] },
  ]
  resource_quota = { "requests.memory" = "4Gi", "limits.memory" = "8Gi" }
}
```

A flow between two namespaces needs **both** sides: an egress rule in the
client namespace and an ingress rule in the server namespace. The server side
of the foundation services is opened through the `*_client_namespaces`
variables of `stacks/12-foundation-services`.

Always reference `module.<x>.name` (not the literal string) for resources in
the namespace so they are created after the policies.
