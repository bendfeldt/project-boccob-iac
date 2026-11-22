# 20-catalog

Apache Polaris in namespace `catalog`: PostgreSQL metastore `polaris-db`
(CloudNativePG, namespace `database`), TLS on 8181, one internal catalog per
data layer, service principals `trino` and `ingest`.

```
make deploy ENV=<env> STACK=20-catalog
```

| Secret | OpenBao KV path |
|---|---|
| root principal (`client-id`, `client-secret`, `realm`) | `kv/catalog/polaris/root` |
| token signing key | `kv/catalog/polaris/token-broker` |
| principal credentials (`client-id`, `client-secret`, `credential`, `scope`) | `kv/catalog/polaris/principals/<name>` |

Changing `layers` or `principals` re-runs the idempotent provisioning Job
(`polaris-provision-<hash>`); privileges removed from the variable are revoked.
Design notes: docs/data-plane.md.
