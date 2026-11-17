# site DNS serves *.<base_domain> to pods as well -> no CoreDNS rewrite needed.
# Set true (and exclude the registry name) if pods cannot resolve the ingress names.
ingress_dns_rewrite = false
