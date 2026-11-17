# prometheus

Prometheus server + Alertmanager (prometheus-community chart) with explicit
scrape jobs (`scrape_jobs`: pod discovery by namespace + container port;
`static_jobs`: HTTPS endpoints) and alert rules (`alert_rules`). Annotation
based discovery is disabled; node-exporter and pushgateway are off;
kube-state-metrics is optional (`kube_state_metrics_enabled`, image must be in
versions.yaml). Every target needs a NetworkPolicy opening on both sides.
The Prometheus web endpoint is plain HTTP inside the namespace (open item:
`--web.config.file` TLS).
