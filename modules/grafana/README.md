# grafana

Grafana with Keycloak OIDC as the only login (no login form, no basic auth, no
anonymous access, no initial admin user), roles from the Keycloak `groups`
claim, provisioned data sources and dashboards (own ConfigMap), HTTPS with a
certificate from the platform PKI. Read-only root filesystem, no persistence
(dashboards and data sources are code; user preferences are lost on restart).

Grafana OSS has no per-data-source permissions. Stack 30 therefore runs two
instances: `grafana` (Prometheus + ordinary logs) and `grafana-audit` (audit
trail only, `role_mapping.strict = true`: only the auditor groups can log in).

Status: rendered with `helm template` from the planned values (no upstream
images left); not deployed on the build machine (image ~480 MB, disk budget).
Prerequisites: Keycloak clients `grafana` and `grafana-audit` (stack 13-identity),
DNS / `DEV_INGRESS_HOSTS` entries for `grafana` and `grafana-audit`.
