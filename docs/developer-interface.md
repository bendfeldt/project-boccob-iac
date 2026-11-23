# Platform -> developer interface

The solution repository (data code) and this repository (platform) are separate. Neither
contains code or file paths of the other. They meet only through:

1. **Artifacts in Zot, by digest.** The solution builds and pushes its code-location image and
   OPA policy bundle to `<registry>/boccob/<name>`. This repository signs them
   (`make sign ENV=<env> REFS=...`, OpenBao transit key), transfers them into air-gapped
   environments (`make solution-bundle` / `make solution-load`) and deploys them from the
   digests in `environments/<env>/21-query.tfvars` (`opa_bundle_ref`) and
   `22-orchestration.tfvars` (`dagster_code_location_image`).
2. **One file, written by the platform, read by the solution's developer tools** (dev only):

```bash
make dev-env ENV=dev     # creates the dev test users, then writes the file below
export BOCCOB_PLATFORM_ENV=~/.boccob/dev/developer.env    # for the solution repository
```

`~/.boccob/dev/developer.env` lies outside both checkouts, is mode 0600 and is regenerated on
every run (do not edit it). It needs stacks up to `20-catalog`; before `22-orchestration` exists it
warns but still writes the file, so the first solution release can be published
([getting-started.md](getting-started.md), step 8). Format: plain shell `KEY=value` lines (values contain no spaces or
quotes). Secret values are never in the file: keys ending in `_FILE` name a 0600 file outside the
repositories. The key set is exactly the one the solution's platform contract (its
`docs/platform-contract.md`, section 4) reads:

| Key | Value on dev |
|---|---|
| `BOCCOB_ENV` | `dev` |
| `BOCCOB_REGISTRY_HOST`, `BOCCOB_REGISTRY_CA_FILE` | Zot host:port and its CA (`~/.boccob/dev/pki/registry-ca.crt`) |
| `BOCCOB_REGISTRY_USER`, `BOCCOB_REGISTRY_PASSWORD_FILE` | push user `mirror`, `~/.boccob/dev/registry/push-password` |
| `BOCCOB_KUBECONFIG` | `~/.boccob/dev/kubeconfig` |
| `BOCCOB_DAGSTER_NAMESPACE` | `orchestration` |
| `BOCCOB_CODE_LOCATION`, `BOCCOB_CODE_LOCATION_NAME` | `deploy/dagster-code-dagster-user-deployments-lakehouse`, `lakehouse` |
| `BOCCOB_DAGSTER_WEBSERVER`, `BOCCOB_DAGSTER_WEBSERVER_CONTAINER` | `deploy/dagster-dagster-webserver`, `dagster` |
| `BOCCOB_DAGSTER_GRAPHQL_URL` | `http://127.0.0.1:80/graphql` (as seen inside the webserver container) |
| `BOCCOB_DAGSTER_URL` | `https://dagster.<base domain>` (UI, informational) |
| `BOCCOB_CA_BUNDLE` | platform CA bundle (`~/.boccob/dev/pki/platform-ca.crt`) |
| `BOCCOB_TRINO_URL`, `BOCCOB_KEYCLOAK_URL`, `BOCCOB_KEYCLOAK_REALM` | `https://trino.<base domain>`, `https://keycloak.<base domain>`, `lakehouse` |
| `BOCCOB_KEYCLOAK_CLIENT_ID`, `BOCCOB_KEYCLOAK_CLIENT_SECRET_FILE` | `trino` (direct access grants, dev only), `~/.boccob/dev/developer/oidc-trino-client-secret` |
| `BOCCOB_TEST_ANALYST_USER`, `BOCCOB_TEST_ANALYST_PASSWORD_FILE` | the test user with groups exactly `analyst` (`environments/dev/test-users.conf`), its password file in `~/.boccob/dev/test-users/` |
| `BOCCOB_TEST_PII_READER_USER`, `BOCCOB_TEST_PII_READER_PASSWORD_FILE` | the test user with groups exactly `analyst,pii-reader`, its password file |
| `BOCCOB_TEST_AUDITOR_USER`, `BOCCOB_TEST_AUDITOR_PASSWORD_FILE` | the test user with groups exactly `auditor` (reads Trino's query history), its password file |

Rules:

- The solution reads only this file and the artifacts' digests; it never reads files of this
  repository. This repository never reads files of the solution repository.
- Adding, removing or renaming a key is a change of both contracts (this file and the
  solution's), made together.
- test/prod have no such file: their registry host, CA and push credentials are handed to the
  release builder by the platform operators.
