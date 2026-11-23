# project-boccob-iac

The **platform** of the Boccob lakehouse: on premises, open source, air-gapped, k3s everywhere.
OpenTofu only, driven by bash scripts behind a Makefile. The data code (dlt, dbt, Dagster, OPA
policies) lives in the separate solution repository `project-boccob`; clone it next to this one.

**New here?**

1. [docs/overview.md](docs/overview.md): what was built and why (components, stacks, environments,
   security, glossary).
2. [docs/getting-started.md](docs/getting-started.md): set up everything on your machine, step by
   step (Linux x64 is the tested path; macOS on Apple Silicon and a Linux VM are described).

```
make help                  # every target with a one-line description
make doctor ENV=dev        # checks this machine; changes nothing
make tools                 # pinned tofu, helm, cosign, trivy, syft, oras -> ~/.cache/boccob/bin
make cluster-up ENV=dev    # Zot registry + hardened k3s as Podman containers
make airgap-mirror ENV=dev # every locked image (by digest) and chart into Zot
make deploy ENV=dev        # all stacks in order (STACK=12-foundation-services for one)
make verify ENV=dev        # smoke test, about 110 checks
make dev-env ENV=dev       # test users + ~/.boccob/dev/developer.env for the solution repository
```

| Path | Content |
|---|---|
| `versions.yaml` / `versions.lock.yaml` | desired versions / resolved digests and checksums: the only place an image, chart or download is named ([docs/versions.md](docs/versions.md)) |
| `Brewfile` | the macOS (Homebrew) prerequisites |
| `modules/` | reusable OpenTofu modules, one per component, each with a README |
| `stacks/` | ordered OpenTofu root projects, one encrypted state each, each with a README |
| `environments/<env>/` | `env.sh` (script settings) and tfvars (sizing, options) for dev, test, prod ([environments/README.md](environments/README.md)) |
| `scripts/` | everything executable; `scripts/lib` is shared |
| `docs/` | [overview](docs/overview.md), [getting started](docs/getting-started.md), [architecture](docs/architecture.md), [data plane](docs/data-plane.md), [conventions for contributors](docs/conventions.md), [versions and architectures](docs/versions.md), [developer interface](docs/developer-interface.md), [bootstrap runbook for test/prod](docs/runbook-bootstrap.md), [compliance](docs/compliance/README.md), [audit reports](docs/audit/README.md) |

Platforms: clusters run on **linux/amd64 (x64)** or **linux/arm64 (aarch64)**; every image is
pinned per architecture. The x64 Linux dev path is tested; arm64 and macOS (Apple Silicon, in a
podman machine) are prepared but have not run on real hardware.

Secrets, kubeconfigs, CA keys, unseal material and the OpenTofu state never live in this
repository or the solution repository: they are kept in `~/.boccob/<env>/` (mode 0700) or, for
test/prod, with the key custodians and in an off-site state bucket ([docs/runbook-bootstrap.md](docs/runbook-bootstrap.md)).
