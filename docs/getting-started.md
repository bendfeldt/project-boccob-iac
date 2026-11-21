# Getting started: run the Boccob lakehouse yourself

This guide is for a developer who is new to the project. By the end you will have the whole
platform running, with the demo data loaded through all four layers. You can run it in two places:

- **Part A**: on your own machine, as containers.
- **Part B**: on a Linux virtual machine (VM) that you host yourself, for example on your laptop,
  a workstation or a lab server.

Both parts install the same thing: a single-node Kubernetes cluster (k3s) running inside a Podman
container, plus a private image registry (Zot). That is the `dev` environment. The `test` and `prod`
environments install k3s directly on several servers instead; they are covered in
[runbook-bootstrap.md](runbook-bootstrap.md) and are not needed to get started.

> **What has been tested.** The steps in Part A were run end to end on Ubuntu 24.04 on x86_64 (amd64), as
> `root`, with 4 CPU cores and 15 GB RAM. The result was `make verify ENV=dev` passing all checks and
> `scripts/dev/e2e.sh dev` passing 39/39. macOS, Windows/WSL2 and the "k3s directly on the VM" variant
> (Part B, option 2) have **not** been tested. Where this guide describes them, it says so.

---

## 0. The ideas in five minutes

| Thing | What it is | Where it lives |
|---|---|---|
| **Solution** | The data code: ingestion (dlt), transformations (dbt), access policies (OPA), orchestration (Dagster) | repo `project-boccob` |
| **Platform / IaC** | Everything that runs it: k3s, RustFS (S3 storage), Polaris (Iceberg catalog), Trino (SQL), Dagster, OpenBao (secrets), Keycloak (login), monitoring, backups | repo `project-boccob-iac` (OpenTofu + bash) |
| **Zot** | A private container registry. The cluster pulls images **only** from here (the "air-gap" design), never from the internet | Podman container `boccob-dev-zot` |
| **k3s node** | The Kubernetes cluster, running inside one Podman container | Podman container `boccob-dev-server-0` |
| **Stacks** | Ordered OpenTofu projects, each deployed with its own encrypted state: `00-bootstrap`, `10/11/12/13` foundation, `20/21/22` data plane, `30/31/32` ops | `project-boccob-iac/stacks/` |
| **Local secrets** | Kubeconfig, registry CA, OpenBao unseal key, state passphrase | `~/.boccob/dev/` (never in git) |

The two repositories only meet through two **artifacts** published to Zot: the Dagster
code-location image and the OPA policy bundle. You build them from the solution repo, and the IaC
repo deploys them.

Data flows `raw → clean → consolidated → curated`. See `project-boccob/docs/data-layers.md` once you
are up and running.

---

## 1. What you need

### Hardware (for the machine that runs the cluster)

| | Minimum (tested) | Comfortable |
|---|---|---|
| CPU | 4 cores, x86_64 / amd64 | 8 cores |
| RAM | 16 GB | 24 GB+ |
| Free disk | 40 GB (tight: you will have to prune images) | 80 GB+ |

> **amd64 only.** Every image and binary is pinned to `linux/amd64` (see `versions.lock.yaml`). On an
> Apple Silicon Mac (M1–M4) or another ARM machine, the cluster would have to run under x86
> emulation, which is far too slow. Use Part B with an x86 VM on another machine instead.

### Network

You need internet access the first time, to download tools and mirror all images into Zot. After
that, the cluster itself never talks to the internet. If you are behind a company proxy, set
`HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` in your shell before you start. These hosts must be reachable:

- `github.com` and the `*.githubusercontent.com` hosts its release downloads redirect to, plus `raw.githubusercontent.com` (tool and k3s downloads)
- `docker.io` / `registry-1.docker.io`, `ghcr.io` + `pkg-containers.githubusercontent.com`, `quay.io`,
  `registry.k8s.io` (images)
- `get.helm.sh`, `registry.opentofu.org`, `pypi.org` / `files.pythonhosted.org`
- the Helm chart repositories in `versions.yaml` (e.g. `*.github.io` chart sites, `charts.jetstack.io`)

### Root

The dev scripts need **root**. They run rootful Podman with a privileged k3s container, publish ports
80 and 443, set kernel parameters with `sysctl`, and add a block to `/etc/hosts`. Rootless Podman is
not supported. Run every command in this guide in a root shell:

```bash
sudo -i
```

All local state then goes to `/root/.boccob/dev/` and `/root/.cache/boccob/`.

---

## Part A: run it locally

### A.1 Choose your setup

| Your machine | What to do |
|---|---|
| **Linux (Ubuntu 24.04 recommended)** | Continue with A.2 directly on your machine. |
| **Windows 10/11** | *Untested.* Install WSL2 with Ubuntu 24.04 (`wsl --install -d Ubuntu-24.04`), give WSL at least 16 GB RAM in `%UserProfile%\.wslconfig` (`[wsl2]` → `memory=16GB`, `processors=4`), then follow A.2 inside the Ubuntu shell. If WSL gives you trouble, use a Hyper-V VM and follow **Part B** instead. |
| **macOS (Intel)** | Create an Ubuntu 24.04 VM (e.g. with UTM or Multipass, 4+ CPU, 16+ GB RAM, 80 GB disk) and follow **Part B**. The scripts edit Linux kernel settings and `/etc/hosts`, so they cannot run on macOS itself. |
| **macOS (Apple Silicon)** | Not practical locally (amd64 only, see above). Use **Part B** with an x86 VM on another machine. |

> **Why not `podman machine` on macOS/Windows?** It runs Fedora CoreOS, which is immutable and hard to
> install OpenTofu, Helm and the other tools on. The scripts also expect to run on the same Linux host
> as Podman. A normal Ubuntu VM is simpler and is exactly Part B.

### A.2 Install the prerequisites (Ubuntu 24.04)

```bash
sudo -i
apt-get update
apt-get install -y podman skopeo jq yq make git curl openssl shellcheck python3 ca-certificates

# OpenTofu 1.10.6
curl -fsSLo /tmp/tofu.tgz https://github.com/opentofu/opentofu/releases/download/v1.10.6/tofu_1.10.6_linux_amd64.tar.gz
tar -xzf /tmp/tofu.tgz -C /tmp tofu && install /tmp/tofu /usr/local/bin/

# Helm 3.18.6
curl -fsSLo /tmp/helm.tgz https://get.helm.sh/helm-v3.18.6-linux-amd64.tar.gz
tar -xzf /tmp/helm.tgz -C /tmp && install /tmp/linux-amd64/helm /usr/local/bin/

# kubectl (1.33+ works; the cluster runs 1.35)
curl -fsSLo /tmp/kubectl https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl
install /tmp/kubectl /usr/local/bin/

# uv (Python tooling for the solution repo); it fetches Python 3.13 itself
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv python install 3.13
```

Check:

```bash
podman --version; skopeo --version; tofu version | head -1; helm version --short; kubectl version --client | head -1; jq --version; yq --version; uv --version
```

> `yq` must be the **Python** yq from the Ubuntu package (a jq wrapper), not the Go "mikefarah" yq.
> The scripts use jq syntax.

### A.3 Get the code

Clone the two repositories **next to each other**. The IaC scripts find the solution as
`../project-boccob` by default.

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/bendfeldt/project-boccob.git
git clone https://github.com/bendfeldt/project-boccob-iac.git
# while the work is not merged yet, use the development branch in both:
git -C project-boccob checkout claude/determined-lovelace-ugiz1b
git -C project-boccob-iac checkout claude/determined-lovelace-ugiz1b
```

Install the pinned supply-chain tools (cosign, trivy, syft, oras). They are checksum-verified and
installed into `~/.cache/boccob/bin`; the scripts add that directory to `PATH` themselves.

```bash
cd ~/src/project-boccob-iac
make tools
make help          # every target with a one-line description
```

In the solution repo, create the Python environment and its tools once:

```bash
cd ~/src/project-boccob
make setup         # virtualenv from uv.lock
make tools         # pinned opa + oras
make test          # optional sanity check: unit tests, ~1-2 min
```

### A.4 Start the cluster and the registry

```bash
cd ~/src/project-boccob-iac
make cluster-up ENV=dev      # Zot + hardened k3s in Podman, mirrors the cluster images (~5 min)
make airgap-mirror ENV=dev   # every other pinned image + Helm chart into Zot (~10-20 min, several GB)
export KUBECONFIG=~/.boccob/dev/kubeconfig
kubectl get nodes            # one node, STATUS Ready
```

What just happened:

- **Zot.** A registry container started with its own CA. The CA and the push password are in
  `~/.boccob/dev/pki/` and `~/.boccob/dev/registry/`.
- **Images.** Every image and chart listed in `versions.lock.yaml` was copied into Zot,
  byte-for-byte and by digest.
- **k3s.** A hardened k3s node started, configured to pull only from Zot.
- **/etc/hosts.** A marked block was added, mapping `*.dev.lakehouse.internal` to `127.0.0.1`.

### A.5 Deploy the platform (first time)

The data-plane stacks `21-query` and `22-orchestration` need the solution's image and policy bundle,
which do not exist yet in your new Zot. So the first deployment happens in three steps.

**Step 1: deploy the foundation and the catalog, one stack at a time.**

```bash
for s in 00-bootstrap 10-foundation-secrets 11-foundation-pki 12-foundation-services 13-identity 20-catalog; do
  make deploy ENV=dev STACK=$s || break
done
```

`10-foundation-secrets` also initialises and unseals OpenBao. The dev unseal key and root token are
written to `~/.boccob/dev/openbao/`. In test and prod they go to key custodians instead.

**Step 2: build, push and sign the solution release into your Zot.**

```bash
make release-publish ENV=dev
```

This runs the solution repo's own build and push targets, then signs both artifacts with the key held
in OpenBao. At the end it prints two lines like these:

```
opa_bundle_ref = "registry.dev.lakehouse.internal:5000/boccob/opa-policy-bundle@sha256:..."
dagster_code_location_image = "registry.dev.lakehouse.internal:5000/boccob/dagster-code-location@sha256:..."
```

Put them into `environments/dev/21-query.tfvars` and `environments/dev/22-orchestration.tfvars`,
replacing the existing lines with the same names. The digests in git belong to someone else's
registry and will not exist in yours.

> If disk is tight, `SBOM=0 make release-publish ENV=dev` skips the SBOM and vulnerability scan at build
> time (they need about 1 GB more).

**Step 3: deploy everything, then check.**

```bash
make deploy ENV=dev          # all stacks in order; already-deployed ones report no changes
make verify ENV=dev          # smoke test, about 100 checks; all should pass
```

**Step 4: load the demo data and prove it end to end.**

```bash
scripts/dev/test-users.sh dev    # creates alice-admin, erik-engineer, anna-analyst, petra-pii, axel-auditor
scripts/dev/e2e.sh dev           # two daily loads, access control, erasure, ... (~15-30 min)
```

The test users' passwords are in `~/.boccob/dev/test-users/<user>`.

### A.6 Open the web UIs

The UIs are served over HTTPS on `127.0.0.1:443`, with certificates from the platform's internal CA.
Your browser does not trust that CA yet. Import `~/.boccob/dev/pki/trust-bundle.crt` as a trusted
authority (Firefox: Settings → Privacy & Security → Certificates → Import; Chrome on Linux:
Settings → Privacy and security → Security → Manage certificates → Authorities).

| URL | What | Log in as |
|---|---|---|
| `https://dagster.dev.lakehouse.internal` | Dagster: runs, assets, schedules | `alice-admin` or `erik-engineer` (via Keycloak) |
| `https://trino.dev.lakehouse.internal` | Trino web UI | any test user (via Keycloak; the browser login itself has not been tested yet; SQL clients with a Keycloak token were) |
| `https://keycloak.dev.lakehouse.internal` | Keycloak, realm `lakehouse` | test users |
| `https://polaris.dev.lakehouse.internal`, `https://s3.dev.lakehouse.internal`, `https://openbao.dev.lakehouse.internal` | Catalog, object storage and secrets APIs | used by tools, not people |

Try it: as `anna-analyst` you can only query the `curated` catalog, and personal data shows as
`*****`. As `petra-pii` you see real values (all synthetic).

### A.7 Everyday commands

| Task | Command |
|---|---|
| Stop the cluster (data is kept) | `make cluster-down ENV=dev` |
| Start it again, or recover after a reboot | `make cluster-up ENV=dev` (also unseals OpenBao) |
| OpenBao is sealed | `make openbao-unseal ENV=dev` |
| See what a change would do | `make plan ENV=dev STACK=<stack>` |
| Apply one stack | `make deploy ENV=dev STACK=<stack>` |
| Health check | `make verify ENV=dev` |
| Publish a new solution release | `make release-publish ENV=dev`, update the two tfvars lines, `make deploy ENV=dev STACK=21-query`, then `STACK=22-orchestration`, then run the Dagster job `migrate` (see `project-boccob/docs/releases.md`) |
| Wipe the demo data, keep the platform (dev only) | `CONFIRM=dev scripts/dev/reset-lakehouse-data.sh dev` |
| Remove everything | `CONFIRM=dev CLUSTER=1 make destroy ENV=dev`, then `rm -rf ~/.boccob/dev` |
| Lint before you commit | `make lint` (in both repos) |

> **Never delete `~/.boccob/dev/` while the cluster exists.** It holds the only copy of the state
> passphrase and the OpenBao unseal key. Without them the environment cannot be recovered; you can only
> destroy it and start over.

---

## Part B: deploy to a Linux VM you host yourself

### B.1 Create the VM

Use any hypervisor: Proxmox, VMware, Hyper-V, VirtualBox, KVM/libvirt, UTM or Multipass.

- Ubuntu Server 24.04 LTS, **x86_64**
- 4+ vCPU (8 is better), 16+ GB RAM (24 GB is better), 80 GB disk
- A network address you can reach from your laptop, with SSH enabled (port 22 open)

Example with Multipass:

```bash
multipass launch 24.04 --name boccob --cpus 4 --memory 16G --disk 80G
multipass shell boccob
```

There are two ways to run the platform on the VM.

| Option | What runs on the VM | Status |
|---|---|---|
| **1. dev environment inside the VM** (recommended) | Exactly Part A: Zot + k3s in Podman | Same steps as the tested path |
| **2. k3s directly on the VM** ("hosts" mode, like test/prod) | k3s installed as a system service from the air-gap node bundle | **Not tested**; meant for real servers; needs extra setup |

### B.2 Option 1: the dev environment inside the VM (recommended)

1. SSH into the VM and follow **Part A, sections A.2 to A.5**, on the VM. You can skip A.6 for now.
   Run everything on the VM, including `make` and `kubectl`.
2. Reach the web UIs from your laptop. The VM publishes them only on its own loopback
   (`127.0.0.1:443`), so tunnel them over SSH. The Keycloak login redirects use the real hostnames
   without a port, so the tunnel must listen on port **443** on your laptop, which needs admin rights:

   ```bash
   # on your laptop (Linux/macOS); keep it running
   sudo ssh -N -L 443:127.0.0.1:443 <you>@<vm-address>
   ```

   On Windows, use the same command in an administrator PowerShell (OpenSSH is built in).

3. On your laptop, map the hostnames to your end of the tunnel. Add this line to `/etc/hosts`
   (Windows: `C:\Windows\System32\drivers\etc\hosts`):

   ```
   127.0.0.1 keycloak.dev.lakehouse.internal trino.dev.lakehouse.internal dagster.dev.lakehouse.internal polaris.dev.lakehouse.internal s3.dev.lakehouse.internal openbao.dev.lakehouse.internal
   ```

4. Copy the CA from the VM and import it into your laptop's browser, as in A.6:

   ```bash
   scp <you>@<vm-address>:/root/.boccob/dev/pki/trust-bundle.crt .   # or copy it via sudo cat on the VM
   ```

5. (Optional) To run `kubectl` from your laptop, tunnel the API as well
   (`ssh -N -L 6443:127.0.0.1:6443 <you>@<vm-address>`) and copy `/root/.boccob/dev/kubeconfig`
   from the VM. The kubeconfig already points to `https://127.0.0.1:6443`.

After the VM reboots, SSH in and run `sudo -i`, then `cd ~/src/project-boccob-iac && make cluster-up ENV=dev`.

### B.3 Option 2: k3s directly on the VM (advanced, untested)

This is the test/prod installation path. It uses 3 servers and 3 agents, a load-balanced API address,
DNS names, an external Zot, Shamir-split OpenBao keys and Kyverno in Enforce mode. Read
[runbook-bootstrap.md](runbook-bootstrap.md) sections 3–5 first.

To use it on a single VM you would create your own environment, e.g. `environments/vm/`, as a copy
of `environments/test/` with:

- one server in `K3S_SERVERS`, no `K3S_AGENTS`, and `K3S_API_ENDPOINT` set to the VM's name;
- `ha = false` in `common.tfvars`, and dev-sized tfvars;
- a Zot registry reachable from the VM under `REGISTRY_HOST`;
- OpenBao settings for a single member.

You would then build the node bundle (`make node-bundle`), run `make cluster-up ENV=vm` (which
installs k3s over SSH), mirror, and deploy as in A.4–A.5.

None of this has been run. Expect to debug it, and ask a platform maintainer before going down this
path. For learning and day-to-day development, use Option 1.

---

## 2. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `required command not found: X` | A prerequisite is missing; see A.2. For cosign/trivy/syft/oras, run `make tools`. |
| `The connection to the server 127.0.0.1:6443 was refused` | The machine restarted, or the node container died. Run `make cluster-up ENV=dev`. |
| `podman ps` says "Up" but commands fail with "cannot exec in a stopped container" | Stale container after a host restart. `make cluster-up ENV=dev` re-creates it from its volumes. |
| Pods fail with secret errors; OpenBao pod `0/1` | OpenBao is sealed after a restart. Run `make openbao-unseal ENV=dev` (retry once if it times out while the pod is still starting). |
| Pods `Evicted`, node has `DiskPressure`, image pulls fail | The disk is full. Free space: `podman exec boccob-dev-server-0 crictl rmi --prune`, `podman image prune -f`, and delete `~/.cache/uv` and `~/.cache/boccob/trivy` (both can be downloaded again). |
| Mirroring fails with 403 / TLS errors | A proxy or firewall blocks a registry host. Check the host list in section 1. Never turn off TLS verification. |
| `deploy.sh` refuses a plan "that deletes or replaces …" | Safety guard against destroying OpenBao, databases or storage. Read the plan; if you really mean it on dev, run it again with `ALLOW_DESTROY=dev`. |
| `ImagePullBackOff` on the Dagster code location or OPA | The tfvars reference a solution digest that is not in your Zot. Repeat A.5 step 2. |
| dbt refuses `--full-refresh` | On purpose outside `LAKEHOUSE_ENV=dev` (it would lose history and break keys). On dev it is allowed. |
| Port 443 or 80 already in use | Stop the other web server. Moving the dev ports (`DEV_HTTPS_PORT`) breaks the Keycloak login redirects. |

Useful commands:

```bash
export KUBECONFIG=~/.boccob/dev/kubeconfig
kubectl get pods -A | grep -v Running          # anything unhealthy?
kubectl -n orchestration logs deploy/<name>     # logs of a component
podman ps -a                                    # the two dev containers
df -h /                                         # disk
```

---

## 3. Where to go next

| You want to… | Read |
|---|---|
| Understand the platform design | [architecture.md](architecture.md), [data-plane.md](data-plane.md) |
| Add a module, stack, secret, bucket, OIDC client or firewall rule | [conventions.md](conventions.md) |
| Add a data source | `project-boccob/docs/adding-a-source.md` |
| Understand the layers, keystore and SCD2 | `project-boccob/docs/data-layers.md`, `project-boccob/docs/keystore.md` |
| Know how personal data is handled (GDPR, CPR, erasure) | `project-boccob/docs/gdpr.md`, [compliance/](compliance/README.md) |
| Ship a release / change a table schema | `project-boccob/docs/releases.md`, [compliance/runbooks/patching.md](compliance/runbooks/patching.md) |
| Install test/prod on real servers | [runbook-bootstrap.md](runbook-bootstrap.md) |
| See what was audited and what is still open | [audit/](audit/) |
