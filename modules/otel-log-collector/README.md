# otel-log-collector

OpenTelemetry Collector (k8s distribution) as a DaemonSet: pod logs from
`/var/log/pods` and the Kubernetes API audit log -> Loki over OTLP/HTTPS.
`audit_sources` (namespace + container + optional body regex) marks lines as
audit (`boccob.audit.source` attribute); the routing connector sends them to
tenant `audit`, everything else to `platform`. Validated with
`otelcol-k8s validate` of the pinned image and running on dev.
Runs as uid 0 (root-owned log files) without capabilities, read-only mounts and
root filesystem, in its own namespace with Pod Security `privileged`.
No file checkpointing (`start_at = end`): lines written while the collector is
restarting can be missed (open item: file_storage extension on a hostPath).
