# Getting started: run the Boccob lakehouse yourself

This guide is for a developer who is new to the project. By the end you will have the whole
platform running, ready for the solution repository (the data code) to be deployed onto it. You
can run it in three places:

- **Part A**: on your own Linux machine (x64 or arm64), as containers.
- **Part B**: on a Linux virtual machine (VM) that you host yourself, for example on your laptop,
  a workstation or a lab server.
- **Part C**: on a Mac with Apple Silicon (M1 to M4), inside a rootful `podman machine`.

All parts install the same thing: a single-node Kubernetes cluster (k3s) running inside a Podman
container, plus a private image registry (Zot). That is the `dev` environment. The `test` and `prod`
environments install k3s directly on several servers instead; they are covered in
[runbook-bootstrap.md](runbook-bootstrap.md) and are not needed to get started.

> **What has been tested.** The steps in Part A were run end to end on Ubuntu 24.04 on x64 (x86_64,
> amd64), as `root`, with 4 CPU cores and 15 GB RAM. The result was `make verify ENV=dev` passing all
> checks. **Not tested:** Part C (macOS / podman machine;
> its code paths were only exercised with stand-ins for `podman` and `uname` on Linux), any arm64
> cluster (the arm64 image digests and binary checksums are resolved and verified against upstream,
> but nothing has run on arm64 yet) and Windows/WSL2. Where this guide describes them, it says so.

---

## 0. The ideas in five minutes

| Thing | What it is | Where it lives |
|---|---|---|
| **Solution** | The data code: ingestion (dlt), transformations (dbt), access policies (OPA), orchestration (Dagster) | repo `project-boccob` |
| **Platform / IaC** | Everything that runs it: k3s, RustFS (S3 storage), Polaris (Iceberg catalog), Trino (SQL), Dagster, OpenBao (secrets), Keycloak (login), monitoring, backups | repo `project-boccob-iac` (OpenTofu + bash) |
| **Zot** | A private container registry. The cluster pulls images **only** from here (the "air-gap" design), never from the internet | Podman container `boccob-dev-zot` |
| **k3s node** | The Kubernetes cluster, running inside one Podman container | Podman container `boccob-dev-server-0` |
| **Stacks** | Ordered OpenTofu projects, each deployed with its own encrypted state: `00-bootstrap`, `10/11/12/13` foundation, `20/21/22` data plane, `30/31/32` ops | `project-boccob-iac/stacks/` |
| **Local secrets and state** | Kubeconfig, registry CA, OpenBao unseal key, OpenTofu state + its passphrase | `~/.boccob/dev/` (never in git) |

The two repositories are completely separate. They only meet through:

- two **artifacts** in Zot, referenced by digest: the Dagster code-location image and the OPA
  policy bundle. The solution repository builds and pushes them; this repository signs and deploys
  them;
- one **file** outside both checkouts, `~/.boccob/dev/developer.env` (`make dev-env ENV=dev`):
  endpoints, CA, registry and test users for the solution's tools
  ([developer-interface.md](developer-interface.md)).

---

## 1. What you need

### Hardware (for the machine that runs the cluster)

| | Minimum (tested) | Comfortable |
|---|---|---|
| CPU | 4 cores, x64 (x86_64/amd64) or arm64 (aarch64) | 8 cores |
| RAM | 16 GB (Mac: 24 GB, the VM takes 16) | 24 GB+ (Mac: 32 GB) |
| Free disk | 40 GB (tight: you will have to prune images) | 80 GB+ (Mac: 100 GB+) |

> **Two architectures.** `versions.lock.yaml` pins every image twice, once per platform
> (`linux/amd64` and `linux/arm64`), and every downloaded binary per platform. The cluster uses
> the digests of its own architecture, which the scripts detect (`uname -m` on Linux, the podman
> machine on macOS). Other platforms are refused with one clear message. Details: [versions.md](versions.md).
>
> `make doctor ENV=dev` checks this machine (architecture, tools, podman, resources, ports) and
> changes nothing. Run it whenever something does not work.

### Network

You need internet access the first time, to download tools and mirror all images into Zot. After
that, the cluster itself never talks to the internet. If you are behind a company proxy, set
`HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` in your shell before you start. These hosts must be reachable:

- `github.com` and the `*.githubusercontent.com` hosts its release downloads redirect to, plus `raw.githubusercontent.com` (tool and k3s downloads)
- `docker.io` / `registry-1.docker.io`, `ghcr.io` + `pkg-containers.githubusercontent.com`, `quay.io`,
  `registry.k8s.io` (images)
- `get.helm.sh`, `registry.opentofu.org`, `pypi.org` / `files.pythonhosted.org`
- the Helm chart repositories in `versions.yaml` (e.g. `*.github.io` chart sites, `charts.jetstack.io`)

### Root (Linux)

On Linux the dev scripts need **root**. They run rootful Podman with a privileged k3s container, publish ports
80 and 443, set kernel parameters with `sysctl`, and add a block to `/etc/hosts`. Rootless Podman is
not supported. Run every command in this guide in a root shell:

```bash
sudo -i
```

All local state then goes to `/root/.boccob/dev/` and `/root/.cache/boccob/`.

On macOS (Part C) you run everything as **your own user**: the rootful part is the podman machine.
The few changes to the Mac itself (`/etc/hosts`, trusting the dev CA) ask for your password with
`sudo`, and only when you opt in.

---

## Part A: run it locally

### A.1 Choose your setup

| Your machine | What to do |
|---|---|
| **Linux (Ubuntu 24.04 recommended), x64 or arm64** | Continue with A.2 directly on your machine. arm64 is untested. |
| **Windows 10/11** | *Untested.* Install WSL2 with Ubuntu 24.04 (`wsl --install -d Ubuntu-24.04`), give WSL at least 16 GB RAM in `%UserProfile%\.wslconfig` (`[wsl2]` → `memory=16GB`, `processors=4`), then follow A.2 inside the Ubuntu shell. If WSL gives you trouble, use a Hyper-V VM and follow **Part B** instead. |
| **macOS (Apple Silicon)** | Follow **Part C** (podman machine). *Untested on real hardware.* Alternative: an arm64 Ubuntu VM (UTM, Multipass) and **Part B**. |
| **macOS (Intel)** | Not supported directly: create an Ubuntu 24.04 x64 VM (e.g. with UTM or Multipass, 4+ CPU, 16+ GB RAM, 80 GB disk) and follow **Part B**. |

### A.2 Install the prerequisites (Ubuntu 24.04)

```bash
sudo -i
apt-get update
apt-get install -y podman skopeo jq yq make git curl openssl shellcheck python3 ca-certificates
ARCH="$(dpkg --print-architecture)"    # amd64 (x64) or arm64

# Helm 3.18.6
curl -fsSLo /tmp/helm.tgz "https://get.helm.sh/helm-v3.18.6-linux-${ARCH}.tar.gz"
tar -xzf /tmp/helm.tgz -C /tmp && install "/tmp/linux-${ARCH}/helm" /usr/local/bin/

# kubectl (1.33+ works; the cluster runs 1.35)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/v1.35.0/bin/linux/${ARCH}/kubectl"
install /tmp/kubectl /usr/local/bin/

```

Check:

```bash
podman --version; skopeo --version; helm version --short; kubectl version --client | head -1; jq --version; yq --version
```

> `yq` must be the **Python** yq from the Ubuntu package (a jq wrapper), not the Go "mikefarah" yq.
> The scripts use jq syntax.

### A.3 Get the code

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/bendfeldt/project-boccob-iac.git
# while the work is not merged yet, use the development branch:
git -C project-boccob-iac checkout claude/determined-lovelace-ugiz1b
```

The solution repository has its own getting-started guide; it can live anywhere.

Install the pinned operator tools (OpenTofu, cosign, trivy, syft, oras). They are
checksum-verified and installed into `~/.cache/boccob/bin` in the build for this machine
(linux/amd64, linux/arm64 or darwin/arm64); the scripts put that directory first in `PATH`
themselves (`export PATH=~/.cache/boccob/bin:$PATH` to use them in your shell).

```bash
cd ~/src/project-boccob-iac
make tools
make doctor ENV=dev  # prerequisites, architecture, ports, disk: fix every FAIL before you go on
make help          # every target with a one-line description
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

**Step 2: publish the solution artifacts into your Zot and sign them.**

```bash
make dev-env ENV=dev       # test users + ~/.boccob/dev/developer.env (developer-interface.md)
```

Build and push the image and the policy bundle with the solution repository's own targets (its
getting-started guide; it reads `developer.env` through `BOCCOB_PLATFORM_ENV`). You get two
references by digest. Sign them with the platform's key in OpenBao:

```bash
make sign ENV=dev REFS="<registry>/boccob/dagster-code-location@sha256:... <registry>/boccob/opa-policy-bundle@sha256:..."
```

Put them into `environments/dev/22-orchestration.tfvars` (`dagster_code_location_image`) and
`environments/dev/21-query.tfvars` (`opa_bundle_ref`), replacing the existing lines. The digests
in git belong to someone else's registry and will not exist in yours.

**Step 3: deploy everything, then check.**

```bash
make deploy ENV=dev          # all stacks in order; already-deployed ones report no changes
make verify ENV=dev          # smoke test, about 100 checks; all should pass
```

The demo data and the end-to-end tests of the data code are run from the solution repository.
The test users (`alice-admin`, `erik-engineer`, `anna-analyst`, `petra-pii`, `axel-auditor`) were
created by `make dev-env`; their passwords are in `~/.boccob/dev/test-users/<user>`.

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


### A.7 Everyday commands

| Task | Command |
|---|---|
| Stop the cluster (data is kept) | `make cluster-down ENV=dev` |
| Start it again, or recover after a reboot | `make cluster-up ENV=dev` (also unseals OpenBao) |
| OpenBao is sealed | `make openbao-unseal ENV=dev` |
| See what a change would do | `make plan ENV=dev STACK=<stack>` |
| Apply one stack | `make deploy ENV=dev STACK=<stack>` |
| Health check | `make verify ENV=dev` |
| Deploy a new solution release | the solution pushes it; `make sign ENV=dev REFS=...`, update the two tfvars lines, `make deploy ENV=dev STACK=21-query`, then `STACK=22-orchestration`; post-deployment steps per the solution's release docs |
| Refresh the developer interface | `make dev-env ENV=dev` |
| Remove everything | `CONFIRM=dev CLUSTER=1 make destroy ENV=dev`, then `rm -rf ~/.boccob/dev` |
| Lint before you commit | `make lint` |

> **Never delete `~/.boccob/dev/` while the cluster exists.** It holds the only copy of the
> OpenTofu state, its passphrase and the OpenBao unseal key. Without them the environment cannot be recovered; you can only
> destroy it and start over.

---

## Part B: deploy to a Linux VM you host yourself

### B.1 Create the VM

Use any hypervisor: Proxmox, VMware, Hyper-V, VirtualBox, KVM/libvirt, UTM or Multipass.

- Ubuntu Server 24.04 LTS, **x64 (x86_64/amd64)** (arm64 should work the same way but is untested)
- 4+ vCPU (8 is better), 16+ GB RAM (24 GB is better), 80 GB disk
- A network address you can reach from your laptop, with SSH enabled (port 22 open)

Example with Multipass:

```bash
multipass launch 24.04 --name boccob --cpus 4 --memory 16G --disk 80G
multipass shell boccob
```

The VM runs exactly Part A: Zot + k3s in Podman. (k3s installed directly on servers is the
test/prod path: [runbook-bootstrap.md](runbook-bootstrap.md).)

### B.2 The dev environment inside the VM

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

---

## Part C: macOS on Apple Silicon (podman machine)

> **Untested on real hardware.** This part was written and its code paths exercised on Linux with
> stand-ins for `podman` and `uname`; nobody has run it on a Mac yet. Expect to debug it, and please
> report what you find. Everything below runs as **your user**, not root.

How it fits together: a **rootful podman machine** (a small Fedora CoreOS VM managed by podman)
runs the two containers, Zot and the k3s node, natively as `linux/arm64`. Everything else (make,
tofu, helm, kubectl, skopeo, cosign, oras, jq, yq) runs on macOS and talks to the VM through the
podman remote connection. No SSH tunnel is needed: podman's gvproxy forwards every port a
container publishes in the VM to the same port on the Mac. Only **non-privileged** ports are used
on the Mac (macOS lets ordinary programs such as gvproxy bind ports below 1024 only on all
interfaces), all on `127.0.0.1`:

| Mac (127.0.0.1) | What | Variable |
|---|---|---|
| 8443 | ingress https (Traefik) | `DEV_HTTPS_PORT` |
| 8080 | ingress http (redirects to https) | `DEV_HTTP_PORT` |
| 6443 | Kubernetes API | `DEV_API_PORT` |
| 5050 | Zot registry (not 5000: AirPlay Receiver uses it on macOS) | port of `REGISTRY_HOST` |
| 443 → 8443, 80 → 8080 | pf redirect (`make macos-ports`, required) | |

**Homebrew is required on macOS.** `Brewfile` in this repository is the single list of the macOS
prerequisites; `make doctor` and the entry points (`make machine-init`, `cluster-up`, `deploy`)
check it and print the exact `brew install ...` line for anything missing.

What the scripts do differently (`CLUSTER_RUNTIME=podman-machine`, automatic on macOS):

| On Linux (Part A) | On macOS (Part C) |
|---|---|
| `sysctl` on the host | inside the VM (`podman machine ssh`), persisted in `/etc/sysctl.d/90-boccob-k3s.conf` there |
| config files bind-mounted from `~/.boccob/dev/` | copied into the VM (`/var/lib/boccob/dev/`, root-owned, SELinux-relabelled) and mounted from there |
| `/etc/hosts` block added (root) | opt-in, with `sudo` (`DEV_MANAGE_ETC_HOSTS=1`); the VM always gets its own entry for the registry |
| registry CA via `SSL_CERT_FILE` | macOS Go programs ignore `SSL_CERT_FILE`: the CA must be trusted in the System keychain (`make macos-trust`) |
| node image `linux/amd64` | node image `linux/arm64` (the VM's architecture) |
| ingress on 127.0.0.1:443/80 | 127.0.0.1:8443/8080 + pf redirect from 443/80 |

### C.1 Install the tools (Homebrew, required)

Install Homebrew first (https://brew.sh). Then, in a checkout of this repository (A.3):

```bash
cd ~/src/project-boccob-iac
make brew-bundle      # = brew bundle --file=Brewfile: bash make podman helm kubernetes-cli jq
                      #   python-yq skopeo openssl@3 git shellcheck
# (the first time, before GNU make is installed: brew bundle --file=Brewfile)
# use the new bash, GNU make and OpenSSL 3 first in PATH (put this into ~/.zprofile)
export PATH="$(brew --prefix)/opt/make/libexec/gnubin:$(brew --prefix)/opt/openssl@3/bin:$(brew --prefix)/bin:$PATH"
bash --version | head -1     # must be 5.x: macOS' own /bin/bash 3.2 is refused by the scripts
make --version | head -1     # GNU Make 4.x: macOS' make 3.81 cannot run the Makefile
yq --version                 # "yq 3.x": the Python yq (jq wrapper)
```

- **yq**: the scripts use jq syntax, so they need the **Python** yq. Homebrew's `yq` formula is the Go
  "mikefarah" yq, which does not work here: install `python-yq` (or `pipx install yq`) and make sure
  `brew uninstall yq` if you had it. `make doctor` tells you which one you have.
- **OpenTofu, cosign, trivy, syft, oras**: `make tools` installs the pinned, checksum-verified
  darwin/arm64 builds into `~/.cache/boccob/bin`. OpenTofu must be exactly the locked version
  (the stacks accept 1.13.x; `make doctor` checks it), so it is not taken from Homebrew.
- Then `make tools`.

### C.2 Create the podman machine

```bash
cd ~/src/project-boccob-iac
make machine-init                     # rootful; defaults: MACHINE_CPUS=6 MACHINE_MEMORY=16384 (MiB) MACHINE_DISK=100 (GB)
make doctor ENV=dev                   # must end with "doctor: OK"
```

`make machine-init` runs `podman machine init --rootful --cpus .. --memory .. --disk-size ..` (or
`podman machine set` on an existing machine, which it stops first; the disk can only grow), starts
it and makes the rootful connection the default. **Rootful is required**: the k3s node is a
privileged container that binds ports 80/443 and needs netfilter and cgroup access. To convert an
existing machine by hand: `podman machine stop; podman machine set --rootful; podman machine start`.
Leave at least 4 GB of RAM for macOS (the script checks it). Another name than the default machine:
`PODMAN_MACHINE=<name>`.

### C.3 Start the cluster

```bash
make macos-ports ENV=dev                                          # pf redirect 443 -> 8443 (sudo, C.4)
DEV_MANAGE_ETC_HOSTS=1 DEV_TRUST_CA=1 make cluster-up ENV=dev   # asks for your sudo password (/etc/hosts, keychain)
make airgap-mirror ENV=dev           # the linux/arm64 images only (the cluster's architecture)
export KUBECONFIG=~/.boccob/dev/kubeconfig
kubectl get nodes -o wide            # one node, Ready, arm64
```

- Without `DEV_MANAGE_ETC_HOSTS=1` the scripts do not touch `/etc/hosts`; `make cluster-up` then
  stops with the exact block to add yourself (`scripts/cluster/etc-hosts.sh dev print`).
- Without `DEV_TRUST_CA=1` it stops and asks you to run `make macos-trust ENV=dev` (adds the registry
  CA to the System keychain with `sudo security add-trusted-cert`). Run `make macos-trust ENV=dev`
  **again after stack `11-foundation-pki`** is deployed: it then also trusts the platform CA, which
  Safari and Chrome need for the web UIs (Firefox: import `~/.boccob/dev/pki/trust-bundle.crt` in
  its own settings). `ACTION=check` shows the state, `ACTION=remove` takes them out again.
### C.4 Ports and URLs: the pf redirect

The public URLs are the same as on Linux, `https://<svc>.dev.lakehouse.internal` (port 443):
Keycloak wants one fixed public URL, and the issuer in every token and all OIDC redirects are
built from it. On the Mac, gvproxy can only forward the non-privileged 8443/8080, so a pf redirect
on the loopback is required.

`make macos-ports ENV=dev` installs a pf (packet filter) redirect on the loopback,
`127.0.0.1:443 → 8443` and `:80 → 8080`, the way Apple's `pf.conf` is meant to be extended: the
rules live in their own anchor file `/etc/pf.anchors/boccob`; `/etc/pf.conf` gets two marked lines
(`rdr-anchor "boccob"` after Apple's `rdr-anchor "com.apple/*"`, and `load anchor "boccob" ...`),
with a backup in `/etc/pf.conf.boccob-backup`; pf is enabled with a reference token (`pfctl -E`)
so other users of pf are not disturbed; a LaunchDaemon `io.boccob.pf` restores it after a reboot.
It is idempotent. `make macos-ports-remove ENV=dev` takes all of it out again (and releases the
token). A macOS update may reset `/etc/pf.conf`: `make doctor` reports the redirect as inactive,
then run `make macos-ports` again.

`DEV_PUBLISH_ADDR` (default `127.0.0.1`) is the address the ports are published on; there is no
need to change it.

Then deploy as in **A.5** and open the UIs as in **A.6** (the same URLs). The solution
artifacts must be built for `linux/arm64` (the cluster's architecture).

Everyday commands are those of **A.7**. In addition: after the Mac restarts, `podman machine start`
before `make cluster-up ENV=dev`; to free the RAM, `make cluster-down ENV=dev` and `podman machine stop`.

---

## 2. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `required command not found: X` | A prerequisite is missing; see A.2. For cosign/trivy/syft/oras, run `make tools`. |
| `The connection to the server 127.0.0.1:6443 was refused` | The machine restarted, or the node container died. Run `make cluster-up ENV=dev`. |
| `podman ps` says "Up" but commands fail with "cannot exec in a stopped container" | Stale container after a host restart. `make cluster-up ENV=dev` re-creates it from its volumes. |
| Pods fail with secret errors; OpenBao pod `0/1` | OpenBao is sealed after a restart. Run `make openbao-unseal ENV=dev` (retry once if it times out while the pod is still starting). |
| Pods `Evicted`, node has `DiskPressure`, image pulls fail | The disk is full. Free space: `podman exec boccob-dev-server-0 crictl rmi --prune`, `podman image prune -f`, and delete `~/.cache/boccob/trivy` (it can be downloaded again). |
| Mirroring fails with 403 / TLS errors | A proxy or firewall blocks a registry host. Check the host list in section 1. Never turn off TLS verification. |
| `deploy.sh` refuses a plan "that deletes or replaces …" | Safety guard against destroying OpenBao, databases or storage. Read the plan; if you really mean it on dev, run it again with `ALLOW_DESTROY=dev`. |
| `ImagePullBackOff` on the Dagster code location or OPA | The tfvars reference a solution digest that is not in your Zot. Repeat A.5 step 2. |
| Port 443 or 80 already in use | Stop the other web server. Moving the dev ports (`DEV_HTTPS_PORT`) breaks the Keycloak login redirects. |
| `... is not supported. Supported: linux amd64/arm64 (x64/aarch64), macOS arm64 (Apple Silicon)` | The machine (or the podman machine) has another platform, e.g. 32-bit, ppc64le, an Intel Mac or a shell under Rosetta. |
| `image X: no linux/arm64 digest` | The lock has no build of that image for your architecture: see [versions.md](versions.md) ("missing_platforms"). |
| macOS: `x509: certificate signed by unknown authority` from skopeo/helm/tofu | The dev CA is not in the System keychain: `make macos-trust ENV=dev`. |
| macOS: `bash ... is too old` / Makefile errors about `.SHELLFLAGS` | Homebrew's bash and GNU make must come first in `PATH` (C.1). |
| macOS: browser cannot reach `https://<svc>.dev.lakehouse.internal` | The pf redirect is not active: `make macos-ports ENV=dev` (`make doctor` shows whether it is active). |
| macOS: `missing Homebrew formulae: brew install ...` | Run that line, or `make brew-bundle`. |
| macOS: `the podman machine is rootless` | `podman machine stop; podman machine set --rootful; podman machine start` (or `make machine-init`). |

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
| Pin or upgrade a version; architectures | [versions.md](versions.md) |
| Add a module, stack, secret, bucket, OIDC client or firewall rule | [conventions.md](conventions.md) |
| Connect the solution's tools to the platform | [developer-interface.md](developer-interface.md) |
| Data sources, layers, keystore, personal data, releases | the solution repository's documentation |
| Compliance evidence and runbooks | [compliance/](compliance/README.md), [compliance/runbooks/patching.md](compliance/runbooks/patching.md) |
| Install test/prod on real servers | [runbook-bootstrap.md](runbook-bootstrap.md) |
| See what was audited and what is still open | [audit/](audit/) |
