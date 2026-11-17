# 30-observability

| Component | Namespace | Notes |
|---|---|---|
| Prometheus + Alertmanager (`modules/prometheus`) | observability | explicit scrape jobs (`local.scrape_jobs`, `local.static_jobs`), alert rules for platform health, OpenBao sealed, certificate expiry, backups, log pipeline |
| Loki single binary (`modules/loki`) | observability | S3 bucket `platform-logs`, HTTPS, tenants `platform` (`log_retention_period`) and `audit` (`audit_retention_period`) |
| OpenTelemetry Collector (`modules/otel-log-collector`) | observability-agent | DaemonSet: pod logs + Kubernetes API audit log; audit classification (`audit_sources`) -> tenant `audit` |
| Grafana (`modules/grafana`, `grafana_enabled`) | observability | OIDC (Keycloak client `grafana`), group -> role mapping, org `Audit` for the auditor group |

Metrics openings in other namespaces come from their stacks: `metrics_namespaces`
(stacks 00 and 12), OpenBao `/v1/sys/metrics` without token (modules/openbao),
Kyverno (stack 31). `observability-agent` runs with Pod Security `privileged`
(read-only hostPath, uid 0 without capabilities) and is listed as a Kyverno
exception in stack 31.

Queries (port-forward or Grafana): `{service_name=~".+"}` with `X-Scope-OrgID: platform`;
audit trail: tenant `audit`, attribute `boccob_audit_source` (structured metadata).

Tamper resistance of the audit trail: `modules/audit-archive` exports the
previous UTC day of tenant `audit` every night to the bucket `platform-audit`
(created with S3 object lock, default retention `audit_archive_lock` in stack 12,
COMPLIANCE mode: not deletable before expiry, not even by the RustFS root user —
verified on dev). Each day has a manifest with the archive sha256 and the sha256
of the previous manifest (hash chain). `platform-logs` (Loki chunks) is versioned;
Loki's compactor must delete for retention, so it cannot be object-locked itself.
