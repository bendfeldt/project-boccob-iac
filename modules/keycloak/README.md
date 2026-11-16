# keycloak

Keycloak (upstream image, no third-party chart) with:

- HTTPS on the pod (certificate from the platform PKI), no plain HTTP listener,
  fixed frontend/issuer URL `https://<hostname>`
- PostgreSQL over verified TLS (`sslmode=verify-full`)
- `replicas > 1`: Infinispan cluster via jdbc-ping, topology spread, PDB
- realm (default `lakehouse`) managed by an idempotent `kcadm` Job:
  realm security settings + audit events, realm roles, one group per role
  (group membership => role), confidential OIDC clients with `groups` and
  audience mappers
- every credential generated in-cluster and stored in OpenBao:
  `kv/identity/keycloak-admin`, `kv/identity/oidc-clients/<client id>`

Token contract for relying parties: `groups` claim (group names without
path) in id/access token and userinfo; realm roles in `realm_access.roles`.

Notes
- `ifResourceExists=OVERWRITE` is used for clients: changing a client
  definition recreates that client (sessions of that client are dropped).
- Groups/roles are created with `SKIP`: memberships survive re-runs.
- The root filesystem is writable because `kc.sh start` re-augments the
  Quarkus application at startup. A pre-built optimised image
  (`kc.sh build`) would allow a read-only root filesystem and faster starts.
- The bootstrap admin is a break-glass account; create personal admin
  accounts and rotate/disable it in test/prod (see docs/runbook-bootstrap.md).
