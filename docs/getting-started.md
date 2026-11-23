# Getting started: set up the whole platform on your machine

This is the single, ordered setup guide. Follow it from top to bottom. At the end you have the
whole Boccob lakehouse running on your machine (the `dev` environment), with the solution's data
code deployed, demo data loaded and the end-to-end test passed.

Before you start, read [overview.md](overview.md) once: it explains what each part is and why it
exists. Words you do not know are in its glossary.

> **What was tested and what was not**
>
> | Path | Status |
> |---|---|
> | Linux x64 (Ubuntu 24.04, x86_64), as `root`, 4 CPU, 15 GB RAM | **Tested.** Steps 1-6 and 9-13 were run on this path; `make verify ENV=dev` passes (about 110 checks). The first-deployment order of steps 7-8 was run when the environment was first built; its current form (writing `developer.env` before stack 22 exists) has not been re-run from an empty machine |
> | macOS on Apple Silicon (podman machine) | **Not tested on a real Mac.** The macOS code paths were only exercised on Linux with stand-ins for `podman` and `uname`. Expect to debug, and please report what you find |
> | A Linux VM you host yourself | The VM runs the tested Linux path; the SSH tunnel and laptop setup were **not tested** |
> | arm64 clusters (Linux arm64, Apple Silicon) | **Not tested.** The arm64 image digests and binary checksums are resolved and checked against upstream; nothing has run on arm64 yet |
> | test/prod on real servers, the HA profile | **Not tested** (no hosts were available): see [runbook-bootstrap.md](runbook-bootstrap.md) |
> | Windows / WSL2 | Not supported and not tested; use a Linux VM |

## Contents

- [What you need](#what-you-need)
- [Step 1. Install the prerequisites](#step-1-install-the-prerequisites)
- [Step 2. Get both repositories](#step-2-get-both-repositories)
- [Step 3. Install the pinned tools and check your machine](#step-3-install-the-pinned-tools-and-check-your-machine)
- [Step 4. macOS only: create the podman machine and the port redirect](#step-4-macos-only-create-the-podman-machine-and-the-port-redirect)
- [Step 5. Start the cluster and the registry](#step-5-start-the-cluster-and-the-registry)
- [Step 6. Mirror all images into the registry](#step-6-mirror-all-images-into-the-registry)
- [Step 7. Deploy the foundation (first round)](#step-7-deploy-the-foundation-first-round)
- [Step 8. Publish the first solution release and deploy the rest](#step-8-publish-the-first-solution-release-and-deploy-the-rest)
- [Step 9. Check the platform](#step-9-check-the-platform)
- [Step 10. Trust the CA and open the web UIs](#step-10-trust-the-ca-and-open-the-web-uis)
- [Step 11. Apply the schema migrations](#step-11-apply-the-schema-migrations)
- [Step 12. Load the demo data and run the end-to-end test](#step-12-load-the-demo-data-and-run-the-end-to-end-test)
- [Step 13. Everyday commands](#step-13-everyday-commands)
- [Option: a Linux VM you host yourself](#option-a-linux-vm-you-host-yourself)
- [macOS details](#macos-details)
- [Troubleshooting](#troubleshooting)
- [Where to go next](#where-to-go-next)

## What you need

### Hardware

| | Linux (tested) | Mac with Apple Silicon |
|---|---|---|
| CPU | 4 cores, x64 (x86_64/amd64) or arm64; 8 is better | M1 or newer; the podman machine gets 6 cores |
| RAM | 16 GB (15 GB worked); 24 GB is better | 24 GB or more: the podman machine takes 16 GB |
| Free disk | 40 GB; 80 GB is comfortable | 100 GB for the podman machine's disk |

What uses the disk on the tested machine: about 22 GB of Podman volumes (Zot with all mirrored
images, the k3s node with its pulled images and data), plus about 1 GB of tools and caches in
`~/.cache/boccob/`. The k3s node starts evicting pods when less than **1 GiB** is free
(see [Troubleshooting](#troubleshooting)).

### Network

The first setup downloads tools and copies every image into your local registry, so it needs
internet access. After that the cluster never talks to the internet. Behind a company proxy, set
`HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` in your shell before you start, and add
`.lakehouse.internal` to `NO_PROXY`. These hosts must be reachable:

- `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`,
  `raw.githubusercontent.com` (tools, k3s)
- `get.helm.sh` (Helm), `dl.k8s.io` (kubectl), `registry.opentofu.org` (OpenTofu providers)
- `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`, `ghcr.io`,
  `pkg-containers.githubusercontent.com`, `quay.io`, `registry.k8s.io` (images)
- the Helm chart sites listed in [versions.yaml](../versions.yaml) (for example
  `charts.jetstack.io`, `*.github.io`, `downloads.apache.org`, `charts.rustfs.com`)
- `pypi.org`, `files.pythonhosted.org` (the solution's image build)

`DOCTOR_NETWORK=1 make doctor ENV=dev` checks the main ones.

### Time

| Step | Typical time |
|---|---|
| 1-3 prerequisites, tools | 15 min |
| 5 cluster up | 5 min |
| 6 mirror | 10-20 min (several GB) |
| 7 foundation deploy | 15-20 min |
| 8 first solution release + remaining stacks | 20-30 min (the image build is most of it) |
| 9 verify | 5-10 min |
| 12 end-to-end test | 15-30 min |

Plan half a day for the first time.

### Root (Linux) or your own user (macOS)

**Linux:** the dev scripts need **root**. They run rootful Podman with a privileged k3s container,
publish ports 80 and 443, set kernel parameters with `sysctl` and add a block to `/etc/hosts`.
Rootless Podman is not supported. Run every command in this guide in a root shell (`sudo -i`).
Your local state then goes to `/root/.boccob/dev/` and `/root/.cache/boccob/`.

**macOS:** run everything as **your own user**. The rootful part is inside the podman machine (a
small Linux VM). The few changes to the Mac itself (`/etc/hosts`, the keychain, the port redirect)
ask for your password with `sudo`.

### Where your local secrets live

Everything secret or machine-specific lives **outside both checkouts**, in `~/.boccob/dev/`
(mode 0700): kubeconfig, registry CA and push password, OpenBao unseal key and root token, the
OpenTofu state and its passphrase, test-user passwords, `developer.env`. Tools and download caches
are in `~/.cache/boccob/`.

> **Never delete `~/.boccob/dev/` while the cluster exists.** It holds the only copy of the
> OpenTofu state, its passphrase and the OpenBao unseal key. Without them the environment cannot
> be recovered; you can only destroy it and start over.

---

## Step 1. Install the prerequisites

The lists below are exactly what `make doctor` checks. Helm, OpenTofu, cosign, trivy, syft and
oras are **not** in these lists: `make tools` (step 3) installs the pinned versions.

### Linux (Ubuntu 24.04)

```bash
sudo -i
apt-get update
apt-get install -y podman skopeo jq yq make git curl openssl shellcheck python3 ca-certificates
ARCH="$(dpkg --print-architecture)"    # amd64 (x64) or arm64

# kubectl, the version the cluster runs (k3s v1.37.2)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/v1.37.2/bin/linux/${ARCH}/kubectl"
install /tmp/kubectl /usr/local/bin/

# uv (Python package manager) for the solution repository; it also installs Python 3.13
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Check:

```bash
podman --version; skopeo --version; kubectl version --client | head -1; jq --version; yq --version; uv --version
```

- `yq` must be the **Python** yq from the Ubuntu package (a wrapper around jq), not the Go
  "mikefarah" yq. The scripts use jq syntax. `make doctor` tells you which one you have.
- `shellcheck` is needed only for `make lint`.

### macOS (Apple Silicon): Homebrew is required

Install Homebrew first (https://brew.sh). The file [Brewfile](../Brewfile) in this repository is
the single list of the macOS prerequisites: `bash`, `make`, `podman`, `kubernetes-cli` (kubectl),
`jq`, `python-yq`, `skopeo`, `openssl@3`, `git`, `shellcheck`. You install it in step 3, after the
clone (`make brew-bundle`). For the solution repository also run `brew install uv`.

Then put the Homebrew bash, GNU make and OpenSSL 3 first in your `PATH` (add this line to
`~/.zprofile` and open a new terminal):

```bash
export PATH="$(brew --prefix)/opt/make/libexec/gnubin:$(brew --prefix)/opt/openssl@3/bin:$(brew --prefix)/bin:$PATH"
```

- macOS ships bash 3.2 and make 3.81; the scripts need bash 4+ and GNU make 3.82+.
- **yq**: install `python-yq`, not the `yq` formula (that is the Go yq). If you had it:
  `brew uninstall yq`.

**Success looks like:** every check command prints a version.

## Step 2. Get both repositories

Clone the two repositories **next to each other**. They are separate on purpose; neither reads
files of the other.

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/bendfeldt/project-boccob-iac.git   # the platform (this repository)
git clone https://github.com/bendfeldt/project-boccob.git       # the solution (data code)
# while the work is not merged yet, use the development branch in both:
git -C project-boccob-iac checkout claude/determined-lovelace-ugiz1b
git -C project-boccob     checkout claude/determined-lovelace-ugiz1b
```

**Success looks like:** `ls ~/src` shows `project-boccob` and `project-boccob-iac`.

## Step 3. Install the pinned tools and check your machine

```bash
cd ~/src/project-boccob-iac
brew bundle --file=Brewfile   # macOS only (= make brew-bundle, which needs GNU make from this list)
make tools            # pinned OpenTofu, Helm, cosign, trivy, syft, oras -> ~/.cache/boccob/bin
export PATH="$HOME/.cache/boccob/bin:$PATH"   # to use them in your own shell (the scripts do this themselves)
make doctor ENV=dev   # checks this machine; changes nothing
make help             # every target with a one-line description
```

`make tools` downloads the build for this machine (linux/amd64, linux/arm64 or darwin/arm64) of
each tool pinned in `versions.lock.yaml` and checks its sha256. `make doctor` requires OpenTofu and
Helm in **exactly** the locked versions (a Homebrew or system `helm`/`tofu` earlier in a shell's
PATH does not matter: the scripts put `~/.cache/boccob/bin` first).

**Success looks like:** `make doctor` ends with `doctor: OK (N warning(s))`. Fix every `FAIL`
before you continue. On a fresh machine, warnings about the cluster architecture or the registry
name are normal until step 5.

## Step 4. macOS only: create the podman machine and the port redirect

Skip this step on Linux.

```bash
cd ~/src/project-boccob-iac
make machine-init         # rootful podman machine; MACHINE_CPUS=6 MACHINE_MEMORY=16384 MACHINE_DISK=100
make macos-ports ENV=dev  # pf redirect 127.0.0.1:443 -> 8443 and :80 -> 8080 (asks for sudo)
make doctor ENV=dev       # must end with "doctor: OK"
```

Why: the k3s node runs in the VM, and podman can only forward the unprivileged ports 8443/8080 to
the Mac. The public URLs must stay on port 443 (Keycloak builds every login redirect from one fixed
URL), so a pf redirect on the loopback maps 443 to 8443. Details in [macOS details](#macos-details).

**Success looks like:** `podman machine list` shows the machine running; doctor reports
`machine is rootful` and `pf redirect active`.

## Step 5. Start the cluster and the registry

Linux:

```bash
cd ~/src/project-boccob-iac
make cluster-up ENV=dev
export KUBECONFIG=~/.boccob/dev/kubeconfig
kubectl get nodes
```

macOS:

```bash
cd ~/src/project-boccob-iac
DEV_MANAGE_ETC_HOSTS=1 DEV_TRUST_CA=1 make cluster-up ENV=dev   # asks for sudo: /etc/hosts and the keychain
export KUBECONFIG=~/.boccob/dev/kubeconfig
kubectl get nodes -o wide
```

What `make cluster-up` does (about 5 minutes):

1. Starts **Zot** (`boccob-dev-zot`) with its own CA and push password
   (`~/.boccob/dev/pki/registry-ca.crt`, `~/.boccob/dev/registry/push-password`).
2. Copies the cluster's own images (the `cluster` group) into Zot.
3. Sets kernel parameters, renders the hardened k3s configuration and starts the **k3s node**
   (`boccob-dev-server-0`), which pulls only from Zot.
4. Writes `~/.boccob/dev/kubeconfig` and adds a marked block to `/etc/hosts`
   (`<svc>.dev.lakehouse.internal` and the registry name -> `127.0.0.1`; on macOS only with
   `DEV_MANAGE_ETC_HOSTS=1`).

It is idempotent: run it again whenever the machine restarted. It then re-creates stale containers
from their volumes and unseals OpenBao.

**Success looks like:** the last line is `dev cluster is up`, and `kubectl get nodes` shows one
node `boccob-dev-server-0` with `STATUS Ready` (macOS: architecture `arm64`).

## Step 6. Mirror all images into the registry

```bash
make airgap-mirror ENV=dev   # every other locked image (by digest) and chart into Zot; 10-20 min
make airgap-check ENV=dev    # Zot holds every locked image and chart
```

Only the images of the cluster's architecture are copied. On dev the upstream signature check
and the Trivy scan are skipped (`SKIP_SUPPLY_CHAIN=1` in `environments/dev/env.sh`); test/prod
always run them. Grafana is not mirrored on dev (it is not deployed there).

**Success looks like:** `make airgap-check` ends without an error and lists no missing images.

## Step 7. Deploy the foundation (first round)

Stacks `21-query` and `22-orchestration` need the solution's image and policy bundle, which do not
exist in your new registry yet. So the first deployment goes in two rounds. Round one deploys the
stacks that do not need them, one at a time:

```bash
cd ~/src/project-boccob-iac
for s in 00-bootstrap 10-foundation-secrets 11-foundation-pki 12-foundation-services 13-identity 20-catalog; do
  make deploy ENV=dev STACK=$s || break
done
```

- `10-foundation-secrets` also initialises and unseals OpenBao. On dev the unseal key and root
  token go to `~/.boccob/dev/openbao/init.json` (test/prod: encrypted to key custodians).
- Every apply first writes a plan and refuses it if it would delete or replace something that
  cannot be recreated (OpenBao data, a database, the storage). See "destroy guard" in
  [Troubleshooting](#troubleshooting).

**Success looks like:** each stack ends with `Apply complete!`, and
`kubectl get pods -A | grep -v -E 'Running|Completed'` shows only the header line after a minute or two.

## Step 8. Publish the first solution release and deploy the rest

**8a. Write the developer environment file** (platform repository):

```bash
cd ~/src/project-boccob-iac
make dev-env ENV=dev
```

This creates the Keycloak test users and writes `~/.boccob/dev/developer.env`: the registry, its
CA and push credential, the endpoints and the test users, for the solution's tools
([developer-interface.md](developer-interface.md)). Before stack 22 exists it warns that the
Dagster deployments are missing; that is expected here.

| Test user | Groups | Password file |
|---|---|---|
| `alice-admin` | `platform-admin` | `~/.boccob/dev/test-users/alice-admin` |
| `erik-engineer` | `data-engineer` | `~/.boccob/dev/test-users/erik-engineer` |
| `anna-analyst` | `analyst` | `~/.boccob/dev/test-users/anna-analyst` |
| `petra-pii` | `analyst`, `pii-reader` | `~/.boccob/dev/test-users/petra-pii` |
| `axel-auditor` | `auditor` | `~/.boccob/dev/test-users/axel-auditor` |

(The list is `environments/dev/test-users.conf`.)

**8b. Build and publish the solution** (solution repository):

```bash
cd ~/src/project-boccob
make setup                 # Python virtualenv from uv.lock
make tools                 # pinned opa + oras into .tools/bin
export BOCCOB_PLATFORM_ENV=~/.boccob/dev/developer.env
make publish               # build the image, smoke test, push image + OPA bundle, print two references
```

`make publish` builds the image natively for your machine's architecture (linux/arm64 inside the
podman machine on a Mac). It ends by printing:

```
dagster_code_location_image = "registry.dev.lakehouse.internal:5000/boccob/dagster-code-location@sha256:..."
opa_bundle_ref              = "registry.dev.lakehouse.internal:5000/boccob/opa-policy-bundle@sha256:..."
```

**8c. Point the platform at your release** (platform repository). Replace the existing line in
each file with the printed one. The digests committed in git belong to another machine's registry
and do not exist in yours.

| File | Line |
|---|---|
| `environments/dev/22-orchestration.tfvars` | `dagster_code_location_image = "..."` |
| `environments/dev/21-query.tfvars` | `opa_bundle_ref = "..."` |

**8d. Deploy everything, then sign the release:**

```bash
cd ~/src/project-boccob-iac
make deploy ENV=dev    # all stacks in order; the ones from step 7 report no changes
make sign ENV=dev REFS="<image reference> <bundle reference>"   # the two values from 8b, without the variable names
make dev-env ENV=dev   # again, now without the warning
```

`make sign` uses the cosign key in OpenBao, which stack `31-policy` creates; that is why it comes
after the full deploy. On dev, Kyverno only reports unsigned images (`Audit`), so the pods start
before the signature exists; `make verify` checks that the signature is there.

**Success looks like:** `make deploy` ends without an error;
`kubectl -n orchestration get deploy` shows `dagster-code-dagster-user-deployments-lakehouse`
ready; `make sign` prints `signed ...` twice.

## Step 9. Check the platform

```bash
make verify ENV=dev
```

About 110 checks: cluster hardening, PKI, secrets, network policies, storage, databases and their
backups, Keycloak, Polaris, Trino, OPA, Dagster, the admission policies, the audit trail, a
backup restore test and the signatures of the deployed solution artefacts. It runs no solution job.
`VERIFY_RESTORE_TEST=0 make verify ENV=dev` skips the restore test (a few minutes faster).

**Success looks like:** the summary reports every check passed and the exit code is 0.

## Step 10. Trust the CA and open the web UIs

The UIs use certificates from the platform's own CA, which your browser does not trust yet.

- **Linux, Firefox:** Settings → Privacy & Security → Certificates → View Certificates →
  Authorities → Import `~/.boccob/dev/pki/platform-ca.crt` (the root CA is the first certificate
  in that file), tick "trust this CA to identify websites".
- **Linux, Chrome/Chromium:** Settings → Privacy and security → Security → Manage certificates →
  Authorities → Import the same file.
- **macOS (Safari, Chrome):** `make macos-trust ENV=dev`. It adds the registry CA and the platform
  root CA to the System keychain (run it after `make dev-env`, which writes `platform-ca.crt`).
  `ACTION=check` shows the state. Firefox has its own store: import the file as above.

| URL | What | Log in as |
|---|---|---|
| `https://dagster.dev.lakehouse.internal` | Dagster: runs, assets, schedules | `alice-admin` or `erik-engineer` (Keycloak) |
| `https://trino.dev.lakehouse.internal` | Trino web UI | any test user (Keycloak). Browser login was not tested; SQL clients with a Keycloak token were |
| `https://keycloak.dev.lakehouse.internal` | Keycloak, realm `lakehouse` | test users (account console); admin: `kv/identity/keycloak-admin` in OpenBao |
| `https://s3-console.dev.lakehouse.internal` | RustFS console | RustFS root credentials (`kv/storage/rustfs-root`) |
| `https://polaris.dev.lakehouse.internal`, `https://s3.dev.lakehouse.internal`, `https://openbao.dev.lakehouse.internal` | catalog, S3 and secrets APIs | used by tools, not by people |

A password: `cat ~/.boccob/dev/test-users/alice-admin`.

**Success looks like:** the Dagster URL redirects to a Keycloak login page; after logging in as
`alice-admin` you see the code location `lakehouse` with its jobs.

## Step 11. Apply the schema migrations

After deploying a solution release, launch the Dagster job **`migrate`** once: in the Dagster UI,
Jobs → `migrate` → Materialize. It applies the files in the solution's `transform/migrations/`
(`V0001` to `V0003` today) that the lake has not seen yet. On a new, empty lake they are recorded
without effect. The jobs `transform`, `erasure` and `retention` also apply pending migrations as
their first step, so step 12 would do it as well. Why migrations exist: the solution's
`docs/releases.md`.

**Success looks like:** the run succeeds; its metadata lists the applied versions.

## Step 12. Load the demo data and run the end-to-end test

```bash
cd ~/src/project-boccob
export BOCCOB_PLATFORM_ENV=~/.boccob/dev/developer.env
make e2e
```

`make e2e` runs, inside the cluster through Dagster: two daily loads of the demo source
(`ingest_borgerportal`, each followed by `transform`), then checks the content of every layer, the
keystore and SCD2, what each test user may see (the analyst is denied raw and sees personal data
masked, the pii-reader sees it clear), an erasure and a deregistration, that only the purge jobs get
the purge credential, and that a full refresh is refused outside dev.
`E2E_SKIP_LOADS=1 make e2e` reuses loads that already ran.

On dev the schedules are off; to load more data by hand, launch `ingest_borgerportal` for a
partition (a date) and then `transform` in the Dagster UI.

**Success looks like:** `make e2e` ends without a failed check. In Dagster you see the runs and the
asset graph from `landing/borgerportal/...` to `curated/...`.

## Step 13. Everyday commands

| Task | Command (platform repository unless noted) |
|---|---|
| Stop the cluster (data is kept) | `make cluster-down ENV=dev` (macOS, to free the RAM: then `podman machine stop`) |
| Start it again, or recover after a reboot | `make cluster-up ENV=dev` (macOS: `podman machine start` first). Also unseals OpenBao |
| OpenBao is sealed | `make openbao-unseal ENV=dev` |
| See what a change would do | `make plan ENV=dev STACK=<stack>` (all stacks: without `STACK`) |
| Apply one stack | `make deploy ENV=dev STACK=<stack>` |
| Health check | `make verify ENV=dev` |
| New solution release | solution: `make publish`; platform: update the two tfvars lines, `make deploy ENV=dev STACK=21-query`, `make deploy ENV=dev STACK=22-orchestration`, `make sign ENV=dev REFS="..."`; Dagster: job `migrate` |
| Start the dev lake from scratch | solution: `CONFIRM=dev make reset-dev-data` (deletes ALL lake data of dev) |
| Refresh the developer interface | `make dev-env ENV=dev` |
| Lint before you commit | `make lint` (both repositories) |
| Remove everything | `CONFIRM=dev CLUSTER=1 make destroy ENV=dev`, then `rm -rf ~/.boccob/dev` |

---

## Option: a Linux VM you host yourself

Use this when your laptop is not Linux, or you want to keep the platform off your laptop. The VM
runs exactly the Linux path of this guide. **The tunnel and laptop part below was not tested.**

1. Create a VM with any hypervisor (Proxmox, VMware, Hyper-V, VirtualBox, KVM, UTM, Multipass):
   Ubuntu Server 24.04 LTS x64, 4+ vCPU, 16+ GB RAM, 80 GB disk, SSH enabled. With Multipass:

   ```bash
   multipass launch 24.04 --name boccob --cpus 4 --memory 16G --disk 80G
   multipass shell boccob
   ```

2. On the VM, follow steps 1 to 9 of this guide (skip step 4). Run `make`, `kubectl` and both
   repositories on the VM.
3. Reach the web UIs from your laptop through an SSH tunnel. The Keycloak redirects use the real
   host names without a port, so the tunnel must listen on port **443** on the laptop (admin rights):

   ```bash
   sudo ssh -N -L 443:127.0.0.1:443 <you>@<vm-address>       # keep it running
   ```

4. On the laptop, add this line to `/etc/hosts` (Windows: `C:\Windows\System32\drivers\etc\hosts`):

   ```
   127.0.0.1 keycloak.dev.lakehouse.internal trino.dev.lakehouse.internal dagster.dev.lakehouse.internal polaris.dev.lakehouse.internal s3.dev.lakehouse.internal s3-console.dev.lakehouse.internal openbao.dev.lakehouse.internal
   ```

5. Copy `/root/.boccob/dev/pki/platform-ca.crt` from the VM and import it in the laptop's
   browser as in step 10.
6. Optional, `kubectl` from the laptop: tunnel `6443` as well
   (`ssh -N -L 6443:127.0.0.1:6443 <you>@<vm-address>`) and copy `/root/.boccob/dev/kubeconfig`; it
   already points to `https://127.0.0.1:6443`.

After the VM reboots: `sudo -i`, then `cd ~/src/project-boccob-iac && make cluster-up ENV=dev`.

## macOS details

How it fits together: a **rootful podman machine** (a small Fedora CoreOS VM managed by podman)
runs the two containers, Zot and the k3s node, natively as `linux/arm64`. Everything else (make,
tofu, helm, kubectl, skopeo, cosign, oras, jq, yq) runs on macOS and talks to the VM through the
podman connection. Podman's port forwarder (gvproxy) forwards each published port to the same port
on the Mac, on `127.0.0.1`:

| Mac (127.0.0.1) | What | Variable (`environments/dev/env.sh`) |
|---|---|---|
| 8443 | ingress HTTPS (Traefik) | `DEV_HTTPS_PORT` |
| 8080 | ingress HTTP (redirects to HTTPS) | `DEV_HTTP_PORT` |
| 6443 | Kubernetes API | `DEV_API_PORT` |
| 5050 | Zot registry (not 5000: the AirPlay Receiver uses 5000 on macOS) | port of `REGISTRY_HOST` |
| 443 → 8443, 80 → 8080 | pf redirect (`make macos-ports`, required) | |

What the scripts do differently on macOS (`CLUSTER_RUNTIME=podman-machine`, set automatically):

| Linux | macOS |
|---|---|
| `sysctl` on the host | inside the VM, persisted in `/etc/sysctl.d/90-boccob-k3s.conf` there |
| config files bind-mounted from `~/.boccob/dev/` | copied into the VM (`/var/lib/boccob/dev/`) and mounted from there |
| `/etc/hosts` block added automatically | only with `DEV_MANAGE_ETC_HOSTS=1` (sudo); otherwise `make cluster-up` stops and prints the block to add |
| the registry CA reaches tools through `SSL_CERT_FILE` | Go programs on macOS ignore `SSL_CERT_FILE`: the CA must be in the System keychain (`DEV_TRUST_CA=1` or `make macos-trust`) |
| registry on port 5000 | registry on port 5050 |
| ingress on 127.0.0.1:443/80 | 127.0.0.1:8443/8080 plus the pf redirect from 443/80 |

The pf redirect, as `make macos-ports` installs it: the rules live in their own anchor file
`/etc/pf.anchors/boccob`; `/etc/pf.conf` gets two marked lines (a backup is kept in
`/etc/pf.conf.boccob-backup`); pf is enabled with a reference token so other users of pf are not
disturbed; a LaunchDaemon `io.boccob.pf` restores it after a reboot. `make macos-ports-remove ENV=dev`
removes all of it. A macOS update may reset `/etc/pf.conf`; `make doctor` then reports the
redirect as inactive, and you run `make macos-ports ENV=dev` again.

`make machine-init` runs `podman machine init --rootful` (or `podman machine set` on an existing
machine, which it stops first; the disk can only grow), starts it and makes the rootful connection
the default. Rootful is required: the k3s node is a privileged container. Another machine name than
the default: `PODMAN_MACHINE=<name>`.

---

## Troubleshooting

Run `make doctor ENV=dev` first: it finds most setup problems. Useful commands:

```bash
export KUBECONFIG=~/.boccob/dev/kubeconfig
kubectl get pods -A | grep -v -E 'Running|Completed'   # anything unhealthy?
kubectl -n <namespace> describe pod <pod>              # why a pod does not start
kubectl -n <namespace> logs deploy/<name>              # logs of a component
podman ps -a                                           # the two dev containers
df -h /                                                # disk
```

| Symptom | Cause and fix |
|---|---|
| `The connection to the server 127.0.0.1:6443 was refused` | The machine restarted or the node container stopped. Run `make cluster-up ENV=dev`. |
| `podman ps` shows the containers "Up", but the API is down or commands fail with "cannot exec in a stopped container" | Stale containers after a host restart. `make cluster-up ENV=dev` detects them ("is stale (host restarted?)"), re-creates them from their volumes and unseals OpenBao. |
| OpenBao pod `0/1`, ExternalSecrets not ready, pods fail with secret errors | OpenBao is sealed (it seals itself on every restart). `make openbao-unseal ENV=dev`. Right after a restart the first attempt can time out while the pod starts; `make cluster-up` retries by itself, otherwise run it again. |
| After a restart, `make verify` fails "no pod in a failed/pending state" | CronJob runs (backups, audit archive) failed while OpenBao was still sealed, and evicted pods were left behind. Once OpenBao is unsealed: `kubectl delete pod --field-selector=status.phase=Failed -A`. Re-run a missed nightly audit export: `kubectl -n observability create job audit-archive-rerun-$(date +%s) --from=cronjob/audit-archive`. |
| `make verify` fails "Kyverno: running solution pods pass verify-solution-image-signatures" and lists `dagster-run-...` pods | Finished run pods of an earlier solution release whose image was never signed. Sign that release (`make sign`), or delete the finished run Jobs (`kubectl -n orchestration delete job <dagster-run-...>`; Dagster keeps the run history in its database). |
| Pods `Evicted`, node condition `DiskPressure`, image pulls fail | Less than 1 GiB free on the disk. Free space: `podman exec boccob-dev-server-0 crictl rmi --prune`, `podman image prune -f`, delete `~/.cache/boccob/trivy` and old solution build images. Then delete the evicted pods. |
| Mirroring or `make tools` fails with 403, 407 or TLS errors | A proxy or firewall blocks a host. Check the host list under [Network](#network) and your `HTTPS_PROXY`/`NO_PROXY`. Never turn off TLS verification. |
| The solution's `make publish` cannot download Python packages | The image build runs in its own container. `make publish` passes `HTTPS_PROXY` and `SSL_CERT_FILE` on; see the top of the solution's `scripts/build-image.sh` (`BUILD_PROXY`, `BUILD_CA_BUNDLE`, `UV_DEFAULT_INDEX`). |
| `make deploy` stops with "would delete or replace irreplaceable resources" | The destroy guard: the plan would delete OpenBao data, a namespace, a database, the storage or a volume. Read the plan (`make plan ENV=dev STACK=<stack>`). Only if you really mean it on dev: run again with `ALLOW_DESTROY=dev`. |
| `ImagePullBackOff` on the Dagster code location or on OPA | The tfvars point to a solution digest that is not in your Zot (for example the one from git). Repeat step 8b-8d. |
| `ImagePullBackOff` on a platform image | The image is not mirrored: `make airgap-mirror ENV=dev`, then `make airgap-check ENV=dev`. |
| Dagster job fails with "V000N__... was changed after it was applied" | A migration file changed after the lake applied it (normal only while developing migrations). On dev: `CONFIRM=dev make reset-dev-data` in the solution repository, then run the loads again. Never outside dev: add a new migration instead. |
| `make e2e` or `make publish` says a key is missing in `BOCCOB_PLATFORM_ENV` | `developer.env` is old or missing: `make dev-env ENV=dev`. |
| `checksum mismatch` from `make tools` or a download | The download is broken or was changed upstream. Delete the file in `~/.cache/boccob/downloads/` and run again; if it persists, do not work around it, report it. |
| `required command not found: X` | A prerequisite is missing: step 1; for tofu, helm, cosign, trivy, syft, oras: `make tools`. |
| doctor: `helm X is not the locked Y` or `OpenTofu X is not the locked Y` | `make tools`. |
| Port 443 or 80 already in use (Linux) | Stop the other web server. Moving the dev ports breaks the Keycloak login redirects. |
| `... is not supported. Supported: linux amd64/arm64 (x64/aarch64), macOS arm64 (Apple Silicon)` | Another platform: 32-bit, ppc64le, an Intel Mac, or a shell running under Rosetta. Use a Linux VM. |
| macOS: `port 5000 is used by AirPlay Receiver` | Keep the macOS default registry port 5050 (do not set `REGISTRY_HOST` to `:5000`), or turn off the AirPlay Receiver (System Settings → General → AirDrop & Handoff). |
| macOS: `x509: certificate signed by unknown authority` from skopeo, helm or tofu | The dev registry CA is not in the System keychain: `make macos-trust ENV=dev`. |
| macOS: `bash ... is too old`, or Makefile errors about `.SHELLFLAGS` | Homebrew's bash and GNU make must come first in `PATH` (step 1). |
| macOS: the browser cannot reach `https://<svc>.dev.lakehouse.internal` | The pf redirect is not active (for example after a macOS update): `make macos-ports ENV=dev`. |
| macOS: `missing Homebrew formulae: brew install ...` | Run that line, or `make brew-bundle`. |
| macOS: `the podman machine is rootless` | `podman machine stop; podman machine set --rootful; podman machine start` (or `make machine-init`). |

---

## Where to go next

| You want to... | Read |
|---|---|
| Understand what was built and why | [overview.md](overview.md) |
| The cluster and foundation design | [architecture.md](architecture.md) |
| Polaris, Trino, OPA, Dagster in detail | [data-plane.md](data-plane.md) |
| Pin or upgrade a version; CPU architectures | [versions.md](versions.md) |
| Add a module, stack, secret, bucket, OIDC client or firewall rule | [conventions.md](conventions.md) |
| The interface to the solution repository | [developer-interface.md](developer-interface.md) |
| Data sources, layers, keystore, personal data, releases | the solution repository's `docs/overview.md` |
| Compliance evidence and runbooks | [compliance/README.md](compliance/README.md) |
| Install test/prod on real servers | [runbook-bootstrap.md](runbook-bootstrap.md) |
| Earlier audit reports | [audit/README.md](audit/README.md) |
