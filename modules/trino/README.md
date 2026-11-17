# trino

Trino (official chart) for the lakehouse. See docs/data-plane.md for the
design decisions; summary:

| Concern | Implementation |
|---|---|
| Catalogs | one Iceberg REST catalog per layer on Polaris (OAuth2 client credentials of principal `trino`), native S3 file system on RustFS (path style, TLS) |
| TLS | HTTPS 8443 with a certificate from `openbao-pki` (combined PEM key store); JVM trust store = JRE cacerts + platform CA (`modules/java-truststore`) |
| Internal | coordinator/worker traffic on 8080 authenticated with `internal-communication.shared-secret` (generated, OpenBao), confined by NetworkPolicy |
| Users | `OAUTH2` (Keycloak; web UI, CLI/JDBC external auth, bearer JWTs with audience `trino`), principal = `preferred_username` |
| Service accounts | `PASSWORD`: bcrypt password file rendered by External Secrets from generated passwords in OpenBao (`kv/<kv_prefix>/service-accounts/<name>`) |
| Groups | file group provider; sidecar `group-sync` mirrors Keycloak group membership (admin API, service account client) into the file every 30 s; static groups for service accounts |
| Authorisation | OPA plugin with the policy URIs of the solution's platform contract, permission management disabled |
| Audit | HTTP event listener -> sidecar `audit-log` on 127.0.0.1:8090 -> one JSON line per completed query on stdout (`log_type=trino-query-audit`) |
| Workload management | resource groups admin / etl (`svc-*`) / interactive (per user) |
| Workers | `workers` (0 = coordinator executes), HPA or KEDA (`worker_autoscaling`), graceful shutdown (preStop + `shutdown.grace-period`), PDB + topology spread |
| Metrics | JMX exporter sidecar on 5556 |

Pod security: non-root, read-only root filesystem (emptyDirs for /data/trino
and /tmp), no capabilities.
