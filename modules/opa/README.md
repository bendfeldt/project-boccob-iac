# opa

Open Policy Agent as the decision point of Trino's OPA access control.

- The policy bundle is downloaded by OPA itself as an OCI artefact from Zot;
  `bundle_ref` must be pinned by digest (the solution repository writes it to
  `dist/opa/bundle.ref`). A new policy version is rolled out by changing the
  variable; the pods restart and become ready only after the bundle is active.
- Decision logs (`decision_logs.console`) and server logs are JSON on stdout.
- HTTPS on 8181 and on the diagnostic port 8282 (`tls = true`; OPA serves both with the same certificate; probes use HTTPS).
- NetworkPolicy `opa-access`: API only from `client_pod_labels` (same
  namespace), diagnostics only from `metrics_namespaces`, egress only to the
  registry. The namespace baseline must not allow same-namespace traffic
  wholesale (`allow_same_namespace = false`), otherwise every pod of the
  namespace could query OPA.
- `ndots=1`: the registry host name is resolved as given.

```hcl
module "opa" {
  source                = "../../modules/opa"
  namespace             = module.ns_query.name
  image                 = module.versions.images["opa"].ref
  bundle_ref            = var.opa_bundle_ref
  registry_ca_pem       = var.registry_ca_pem
  registry_egress_cidrs = var.registry_cidrs
  client_pod_labels     = module.trino.coordinator_pod_labels
}
```
