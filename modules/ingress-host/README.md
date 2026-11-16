# ingress-host

One hostname on the hardened Traefik ingress:

- `Ingress` (class `traefik`, entrypoint `websecure` only)
- certificate from the internal CA through cert-manager
  (`cert-manager.io/cluster-issuer: openbao-pki`)
- optional verified TLS to the backend (`backend_tls`): a Traefik
  `ServersTransport` trusting the namespace's `platform-ca` ConfigMap and the
  matching Service annotations

```hcl
module "ingress_trino" {
  source       = "../../modules/ingress-host"
  name         = "trino"
  namespace    = module.ns_query.name         # ingress_controller_ports = [8443], ca_bundle_pem set
  host         = "trino.${var.base_domain}"
  service_name = "trino"
  service_port = 8443
  backend_tls  = { server_name = "trino.query.svc" }
}
```

Remember to open the backend port for the ingress controller in the namespace
baseline (`ingress_controller_ports`) and, for dev, to add the short name to
`DEV_INGRESS_HOSTS` in `environments/dev/env.sh` (/etc/hosts block).
