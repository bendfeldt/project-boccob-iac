# Runbook: incident response (technical hooks)

This runbook covers what the platform provides for detecting, investigating
and documenting incidents. The incident response organisation, the decision
whether an incident is reportable and the reporting itself are organisational
duties **[DPO/legal review]**.

## 1. Reporting timelines (orientation, confirm with legal)

| Regime | To whom | When (from awareness) |
|---|---|---|
| NIS2 Art. 23 (significant incident) | national CSIRT / competent authority (Danish NIS2 implementation) | **early warning within 24 h**, **incident notification within 72 h**, **final report within one month** (intermediate reports on request) |
| GDPR Art. 33 (personal data breach) | Datatilsynet | without undue delay, **where feasible within 72 h**, unless unlikely to result in a risk |
| GDPR Art. 34 | data subjects | without undue delay when the breach is likely to result in a high risk |

Start the clock at awareness; record the time. Prepare the 24 h early warning
with what is known — completeness is not required at that stage.

## 2. Detection hooks

| Signal | Where | Action |
|---|---|---|
| `OpenBaoSealed`, `OpenBaoMetricsMissing` | Alertmanager (`stacks/30-observability`) | unexpected seal = possible tampering/restart; unseal with custodians, check OpenBao audit for the period before |
| `CertificateExpiringSoon`, `CertificateNotReady` | Alertmanager | see `certificate-rotation.md` |
| `PostgreSQLBackupFailed`, `…WALArchiving*`, `BackupJobFailed`, `OpenBaoSnapshotTooOld` | Alertmanager | availability incident; RPO at risk |
| `LogPipelineDropping` | Alertmanager | audit trail incomplete: treat as security relevant |
| `KyvernoPolicyFailures` | Alertmanager, `kubectl get policyreport -A` | unexpected workloads/images |
| `TargetDown` | Alertmanager | availability |
| Kubernetes API audit (`service_name="kube-apiserver"`), OpenBao audit (`k8s_namespace_name="secrets"`), Keycloak events, Trino queries, OPA decisions, Polaris | Loki tenant `audit` (Grafana instance `grafana-audit`, group `auditor`) | investigation |

Configure Alertmanager receivers (`alertmanager_config`, credentials only via
`*_file` and mounted Secrets) — without receivers alerts are only visible in
the Alertmanager UI/API. **[manual]**

## 3. First hour checklist

1. Record time of awareness, reporter, first observations (incident log outside the affected platform).
2. Preserve evidence **before** changing anything:
   - audit trail of the relevant period: run the archive for today
     (`kubectl -n observability create job ir-$(date +%s) --from=cronjob/audit-archive`
     archives the *previous* day; for the current day create the Job from the
     CronJob JSON with `ARCHIVE_DAY=<today>` as in `stacks/30-observability`)
     — objects land object-locked in `s3://platform-audit/loki-audit/<day>/`;
   - `make backup ENV=<env>` (fresh PostgreSQL base backups + OpenBao snapshot);
   - `kubectl get events -A`, `kubectl get policyreport -A -o yaml`, pod logs of affected workloads.
3. Contain: isolate a namespace by deleting its allow policies (default-deny
   remains) or scale the workload to 0; revoke credentials (`key-rotation.md`);
   disable a Keycloak user/client.
4. Decide on reporting (section 1) with the DPO / security officer.

## 4. Investigation queries (LogQL, tenant `audit`)

```
{service_name="kube-apiserver"} | json | user_username!~"system:.*"         # human API activity
{service_name="kube-apiserver"} |= "\"verb\":\"delete\""                      # deletions
{k8s_namespace_name="secrets"} | json | auth_display_name != ""              # OpenBao requests by identity
{k8s_namespace_name="identity"} |= "LOGIN_ERROR"                             # failed logins
{k8s_namespace_name="query", k8s_container_name="audit-log"}                  # Trino queries
{k8s_namespace_name="query", k8s_container_name="opa"} |= "\"result\":false"  # denied access decisions
```

Integrity of archived days: each `manifest.json` holds the sha256 of the
archive and of the previous day's manifest. Recompute
(`sha256sum audit.ndjson.gz`, `sha256sum <previous>/manifest.json`) to show
that no day was altered or removed.

## 5. After the incident

Final report (NIS2: within one month), root cause, corrective actions as code
changes (git), lessons learned, update of risk analysis. **[manual]**
