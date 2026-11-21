# project-boccob-iac

**New here? Start with [docs/getting-started.md](docs/getting-started.md)** (run it locally on Linux,
on your own Linux VM, or on an Apple Silicon Mac in a podman machine). `make doctor ENV=dev` checks
your machine.

Platforms: clusters run on **linux/amd64 (x64, x86_64)** or **linux/arm64 (aarch64)**; every image
is pinned per architecture ([docs/versions.md](docs/versions.md)). The x64 Linux dev path is the
tested one; arm64 and macOS are prepared but have not run on real hardware yet.

Infrastructure as code for the Boccob lakehouse: on-prem, open source,
air-gapped, k3s everywhere. OpenTofu only, driven by bash scripts wrapped in a
Makefile.

```
make help
make doctor ENV=dev          # prerequisites, architecture, ports, resources (read-only)
make cluster-up ENV=dev      # Zot registry + hardened k3s as Podman containers, mirrors the cluster images
make airgap-mirror ENV=dev   # every locked image (by digest) and chart into Zot
make deploy ENV=dev          # all stacks in order (STACK=12-foundation-services for one)
make verify ENV=dev          # smoke test
export KUBECONFIG=~/.boccob/dev/kubeconfig
```

| Path | Content |
|---|---|
| `versions.yaml` / `versions.lock.yaml` | desired versions / resolved digests + checksums (single source of truth) |
| `modules/` | reusable OpenTofu modules, one per component |
| `stacks/` | ordered root modules, one encrypted state each |
| `environments/<env>/` | `env.sh` (script settings) and tfvars (sizing) for dev, test, prod |
| `scripts/` | everything executable; `scripts/lib` is shared |
| `docs/` | [architecture](docs/architecture.md), [conventions for contributors](docs/conventions.md), [versions and architectures](docs/versions.md), [bootstrap runbook](docs/runbook-bootstrap.md) |

Secrets, kubeconfigs, CA keys and unseal material never live in this
repository: they are kept in `~/.boccob/<env>/` (mode 0700) or, for test/prod,
with the key custodians (see the runbook).
