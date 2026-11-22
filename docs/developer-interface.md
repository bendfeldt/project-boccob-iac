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
every run (do not edit it). Format: one `KEY='value'` per line (shell-sourceable, also valid
dotenv); values never contain a single quote. Secret values are never in the file: keys ending in
`_FILE` name a 0600 file that holds the secret.

| Key | Meaning |
|---|---|
| `BOCCOB_INTERFACE_VERSION` | `1`; incremented on an incompatible change |
| `BOCCOB_ENV` | `dev` |
| `BOCCOB_PLATFORM_DIR` | checkout of this repository, for `make -C "$BOCCOB_PLATFORM_DIR" sign ENV=dev REFS=...` and `make ... verify ENV=dev` |
| `BOCCOB_KUBECONFIG` | kubeconfig of the dev cluster |
| `BOCCOB_BASE_DOMAIN` | e.g. `dev.lakehouse.internal`; public hosts are `<svc>.<base domain>` |
| `BOCCOB_CA_BUNDLE` | PEM bundle of the platform CA (every ingress and in-cluster TLS certificate) |
| `BOCCOB_INGRESS_IP`, `BOCCOB_INGRESS_PORT` | where this machine reaches the ingress (`127.0.0.1`, `443` on Linux, `8443` on macOS); use it with `curl --resolve <host>:<port>:<ip>` when `/etc/hosts` is not managed |
| `BOCCOB_NO_PROXY` | internal names that must bypass an outbound proxy |
| `BOCCOB_TRINO_URL`, `BOCCOB_KEYCLOAK_URL`, `BOCCOB_POLARIS_URL`, `BOCCOB_DAGSTER_URL`, `BOCCOB_S3_URL`, `BOCCOB_OPENBAO_URL` | public URLs (always port 443) |
| `BOCCOB_OIDC_ISSUER` | Keycloak realm `lakehouse` |
| `BOCCOB_REGISTRY_HOST`, `BOCCOB_REGISTRY_CA_FILE` | Zot registry and its CA |
| `BOCCOB_REGISTRY_NAMESPACE` | `boccob`: push to `<registry>/boccob/<name>` |
| `BOCCOB_REGISTRY_PUSH_USER`, `BOCCOB_REGISTRY_PUSH_PASSWORD_FILE` | push credentials |
| `BOCCOB_CLUSTER_ARCH` | `amd64` or `arm64`: build the artifacts for `linux/<arch>` |
| `BOCCOB_TEST_USERS` | space-separated `user=group[,group]` (Keycloak realm `lakehouse`) |
| `BOCCOB_TEST_USER_PASSWORD_DIR` | `<dir>/<user>` holds that user's password |
| `BOCCOB_OIDC_TEST_CLIENT`, `BOCCOB_OIDC_TEST_CLIENT_SECRET_FILE` | OIDC client with direct access grants (dev only) for tokens of test users |
| `BOCCOB_TRINO_SERVICE_USER`, `BOCCOB_TRINO_SERVICE_PASSWORD_FILE` | Trino service account (password authentication) |

Rules:

- The solution reads only this file and the artifacts' digests; it never reads files of this
  repository. This repository never reads files of the solution repository.
- A new key is added with a default that keeps old readers working; removing or renaming a key
  increments `BOCCOB_INTERFACE_VERSION`.
- test/prod have no such file: their registry host, CA and push credentials are handed to the
  release builder by the platform operators.
