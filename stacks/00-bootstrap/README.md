# 00-bootstrap

Cluster add-ons with CRDs, installed before anything that uses them:

- namespace `platform-system` with the security baseline
- cert-manager, External Secrets Operator, CloudNativePG operator
- hardening of the k3s-bundled Traefik (`HelmChartConfig`): HTTP->HTTPS
  redirect, TLS >= 1.2 with AEAD suites, strict SNI, no dashboard, no cross
  namespace references, JSON access log
- CoreDNS rewrite so pods resolve `<svc>.<base_domain>` to Traefik

No secrets, no OpenBao dependency. State: Secret `tfstate-default-00-bootstrap`
in namespace `tofu-state`.
