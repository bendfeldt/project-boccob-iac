# Ponytail audit (ultra): project-boccob-iac

Branch `claude/determined-lovelace-ugiz1b` at `4305e45`. Read-only: no files changed and nothing committed. Nothing was deployed, applied, destroyed, planned or published.

What this repo does: It is the infrastructure code for an on-prem, air-gapped lakehouse. OpenTofu "stacks" (ordered root modules, each with its own encrypted state) are driven by bash scripts behind a Makefile. They install k3s (dev: in Podman, on Linux or in a rootful podman machine on an Apple Silicon Mac; test/prod: on hosts), the Zot registry mirror, OpenBao + cert-manager PKI, RustFS, CloudNativePG, Keycloak, Polaris, Trino + OPA, Dagster, observability, Kyverno policies, and backup/DR jobs.
Load assumed: a small platform team (2 to 5 operators) running 3 environments, with prod in HA and OpenBao snapshots every hour (the code's default). Nothing in the code suggests a bigger load.

## Must fix

1. **OpenBao restore picks a snapshot that is about 9 days old** (`scripts/backup/lib.sh:L34-36, L98`)
   - **What this is:** `s3_keys` lists the backup bucket with a single S3 request. `openbao_latest_snapshot` takes the last key of that list as "the newest snapshot". `make restore WHAT=openbao`, `make restore-test` and `make verify` all use it.
   - **Problem:** One S3 list request returns at most 1000 keys, oldest first. With the defaults (hourly snapshots, 30 days kept, 2 objects each) the bucket holds about 1440 keys under `openbao/`. After about 21 days in test/prod, the "newest" snapshot is really the 500th-oldest one, about 9 days old. A restore then silently throws away 9 days of secrets, PKI and policy changes. The same limit makes the verify count of PostgreSQL base backups wrong.
   - **Fix:** Page through the list in `s3_keys`: loop with `continuation-token` until `<IsTruncated>false`. As a shortcut for snapshots only, list with `prefix=openbao/raft-$(date -u +%Y%m%d)`. Either way the change stays inside `s3_keys`.
   - **If we skip it:** The first real OpenBao restore in prod loses days of data. Until then, `make verify` reports "snapshot too old" and everyone thinks the backup job is broken.

2. **The deploy guard lets a plan delete a whole namespace** (`scripts/deploy.sh:L44-58`)
   - **What this is:** `destroy_guard` refuses a saved plan that deletes OpenBao (`vault_*`) objects, CNPG clusters, the RustFS release or PVCs (PersistentVolumeClaims, the disks of the pods).
   - **Problem:** It does not look at `kubernetes_namespace_v1`. Deleting a namespace deletes everything in it. For example, a refactor like the stack 12 to 13 split run without `state mv` puts "delete namespace `database`" in the plan. The guard passes it, the apply deletes the namespace, and CNPG removes every PostgreSQL PVC with it. The same goes for `secrets` (OpenBao raft data) and `storage` (RustFS).
   - **Fix:** Add one more clause to the jq filter: `or (.type | startswith("kubernetes_namespace"))`. No other change is needed.
   - **If we skip it:** One wrong plan in test or prod wipes databases or OpenBao in a single auto-approved apply.

3. **On a Mac, Homebrew's OpenTofu is refused by every stack, and air-gapped operators have no pinned tofu at all** (`Brewfile:L7`, `stacks/*/versions.tf` `required_version = "~> 1.10.0"`, `scripts/doctor.sh:L90`)
   - **What this is:** The Brewfile installs whatever OpenTofu version Homebrew has today. Every stack accepts only 1.10.x. `make doctor` only checks for ">= 1.10.0".
   - **Problem:** Homebrew has shipped OpenTofu 1.11 or newer since late 2025. On a new Mac, `make doctor` says OK and then `make deploy` fails on the first stack with "Unsupported OpenTofu Core version". OpenTofu is also missing from `versions.lock.yaml` binaries, so the air-gap bundle carries no tofu for the operator machines in test/prod.
   - **Fix:** Add `tofu` (linux/amd64, linux/arm64, darwin/arm64) to the `binaries` in `versions.yaml` under group `tools`. `make tools` then installs it into `~/.cache/boccob/bin`, which is already first in `PATH`, and the bundle ships it. Remove `opentofu` from the Brewfile. Make doctor check the exact locked version.
   - **If we skip it:** The macOS path, which the owner requires, fails on first use. Operators with different tofu versions also lock each other out of the shared test/prod state.

4. **The Mac trusts dev CAs for every website, and their keys sit on the laptop** (`scripts/cluster/registry-up.sh:L37-40`, `scripts/cluster/macos-trust.sh:L35-44`, `modules/openbao-config/main.tf:L55-64`)
   - **What this is:** `make macos-trust` adds the registry CA and every certificate in `platform-ca.crt` (root, issuing CA and the cert-manager bootstrap CA) as trusted roots to the macOS System keychain.
   - **Problem:** None of these CAs has name constraints (rules that limit which domain names a CA may sign for). The registry CA key is a user-readable file (`~/.boccob/dev/pki/registry-ca.key`, valid 10 years). The bootstrap CA key can be read by anyone holding the dev kubeconfig. Any process running as the developer can therefore mint a certificate for any bank or Microsoft login page that the whole Mac trusts.
   - **Fix:** Add `-addext "nameConstraints=critical,permitted;DNS:${BASE_DOMAIN},permitted;DNS:${ZOT_NAME},permitted;DNS:localhost,permitted;IP:127.0.0.1/255.255.255.255"` to the registry CA. Set `permitted_dns_domains = [var.base_domain, "svc", "cluster.local", "localhost"]` on the OpenBao root for new environments. In `macos-trust.sh`, trust only the first certificate (the root) of `platform-ca.crt`, never the bootstrap CA. The root has `prevent_destroy`, so the Mac dev environment must be recreated (`cluster-down --purge`).
   - **If we skip it:** On a regulated public-sector laptop, a stolen dev key becomes a man-in-the-middle certificate for any site.

5. **A whole-site loss cannot be recovered: OpenTofu state and the k3s server token exist only inside the site** (`scripts/tofu.sh:L157-167`, `scripts/lib/k3s-config.sh:L24-36`, `docs/compliance/runbooks/disaster-recovery.md` scenario D)
   - **What this is:** The state of all 11 stacks lives in Secrets in the namespace `tofu-state` of the cluster it manages. k3s etcd snapshots are written to the servers' local disks (`etcd-s3` is optional and not set in test/prod).
   - **Problem:** DR scenario D says "OpenTofu state: from the etcd snapshot or re-import". When the site is lost, the etcd snapshots are lost too. Restoring them would also need the server token, which is not on the runbook's list of things kept off-site. The only way left is to re-import hundreds of resources by hand, far beyond the 240-minute RTO (recovery time objective).
   - **Fix:** After each successful apply, `deploy.sh` copies the state Secrets to the backup. The state is already AES-GCM encrypted, so it is safe off-site. Run `kubectl -n tofu-state get secret -o yaml` and upload the result to `platform-backup/tofu-state/` with the S3 helper that is already there, which the off-site copy then carries. Add the k3s server token to the runbook list "kept outside the site", and set `K3S_ETCD_S3_CONFIG_SECRET` for prod.
   - **If we skip it:** The backup and DR requirement is met on paper only. A real site loss means rebuilding by hand.

6. **Every agent node gets the full server join token** (`scripts/cluster/hosts-up.sh:L41-50`, `scripts/lib/k3s-config.sh`)
   - **What this is:** `hosts-up.sh` reads `/var/lib/rancher/k3s/server/token` and copies it to every server and agent as `/root/k3s-token`, where it stays because `config.yaml` points at it.
   - **Problem:** k3s has no separate `agent-token` configured, so an agent holds the server token. Anyone with root on any worker node can join a rogue server, become an etcd member and read every Secret in the cluster (NIS2/ISO: no separation between node roles).
   - **Fix:** Generate an agent token (`random_secret`). Write `agent-token-file:` into the server config. Send that file, not the server token, to the agents. That is about 4 lines in `hosts-up.sh` and `render_k3s_server_config`.
   - **If we skip it:** A single compromised worker in prod turns into a full cluster compromise.

## Should fix

7. **On a default Mac, port 5000 is taken by AirPlay Receiver, and the port setting does not really work** (`environments/dev/env.sh:L7, L32`, `scripts/cluster/registry-up.sh:L143`, `scripts/doctor.sh:L174-178`)
   - **What this is:** Zot is published on `127.0.0.1:5000`, and `REGISTRY_HOST` hard-codes `:5000`.
   - **Problem:** macOS 12 and later listen on port 5000 for AirPlay Receiver by default. `make doctor` then fails with "port 5000 is used by another program" and does not say which program. Setting `DEV_REGISTRY_PORT=5001` changes only the published port, not `REGISTRY_HOST`. The Mac and the VM (whose `/etc/hosts` maps the name to 127.0.0.1) then still pull from `:5000` and fail.
   - **Fix:** Derive the port from one value: `DEV_REGISTRY_PORT="${REGISTRY_HOST##*:}"`, and remove the separate knob. On darwin, the doctor message names AirPlay Receiver (System Settings > General > AirDrop & Handoff), or the dev default moves to a free port such as 5050.
   - **If we skip it:** Every new Mac developer gets stuck on the first `make cluster-up`.

8. **`make verify` and `make restore-test` fail on macOS because of GNU-only `date -d`** (`scripts/verify.d/30-ops.sh:L156`, `scripts/backup/restore-test.sh:L73`)
   - **What this is:** Both files work out the snapshot age with the same copied line: `sed` + `date -u -d`.
   - **Problem:** BSD `date` on macOS has no `-d`. On a Mac, the backup check and the OpenBao snapshot check always report FAIL, even though the rest of the repo was carefully made portable.
   - **Fix:** Add one helper to `scripts/backup/lib.sh`, `snapshot_epoch() { jq -rn --arg k "$1" '$k | capture("raft-(?<t>[0-9T]+Z)").t | strptime("%Y%m%dT%H%M%SZ") | mktime'; }`, and call it from both places. jq is already required on every platform.
   - **If we skip it:** Mac developers learn to ignore red verify results.

9. **Signature checks and scans are off by default on the only path into test and prod** (`scripts/airgap/mirror.sh:L44-56`, `scripts/supply-chain/hooks/*`)
   - **What this is:** cosign verification, Trivy and SBOM run as "hooks" only when `SUPPLY_CHAIN_HOOKS=1` and a second flag per hook (`VERIFY_SIGNATURES`, `SCAN`, `SBOM`) are set. Only the runbook says to set them.
   - **Problem:** `make airgap-bundle ENV=prod`, exactly as `make help` shows it, builds a bundle with no signature check and no scan. `load` cannot tell, and loads it into prod Zot.
   - **Fix:** In `bundle` mode, call `verify-signatures.sh` and `scan.sh` directly and fail on errors. Keep one opt-out (`SKIP_SUPPLY_CHAIN=1`, printed loudly). Delete the hook directories and their double flags (3 files plus `run_hooks`).
   - **If we skip it:** The cosign/Trivy requirement depends on someone remembering four environment variables.

10. **The OpenBao restore puts the admin token on the command line** (`scripts/backup/restore.sh:L41-43`)
    - **What this is:** The snapshot upload is a `curl -H "X-Vault-Token: ${VAULT_TOKEN}"`.
    - **Problem:** During the upload, any local user can see the token in `ps`. In dev it is the root token, in prod a token with sudo on raft. `_bao_call` in `scripts/lib/openbao.sh` already avoids exactly this.
    - **Fix:** `-H @<(printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN")`, the same pattern as `_bao_call`. One line.
    - **If we skip it:** The most privileged token is exposed on a shared operator host.

11. **The guard that protects prod data has no test** (`scripts/deploy.sh:L44-58`)
    - **What this is:** A jq filter over `tofu show -json` decides whether an apply may delete data.
    - **Problem:** Nothing fails when the filter breaks, for example after a provider rename or a typo, or when it misses a type (finding 2). `make lint` already runs tests, but none for this.
    - **Fix:** Move the jq expression to `scripts/lib/destroy-guard.jq`. Add a small fixture plan JSON (delete a namespace, a `vault_mount`, a CNPG Cluster, plus one harmless update) and one `jq -f` assertion in `lint.sh`.
    - **If we skip it:** The last safety net can stop working without anyone noticing.

12. **Two ways to run the public port on macOS, where one is enough** (`environments/dev/env.sh:L20-31`, `scripts/tofu.sh:L112-115`, `stacks/_shared/common.tf:L27-41, L94-97`, `stacks/00-bootstrap/main.tf:L94-101`, `scripts/cluster/dev-up.sh:L82-89`, `scripts/doctor.sh:L179-193`, `scripts/verify.sh:L50-51`)
    - **What this is:** Besides the pf redirect (443 to 8443), there is a second mode, `DEV_PUBLIC_HTTPS_PORT=8443`, with URLs that carry `:8443`.
    - **Problem:** The owner asked for "a forwarded port plus a pf redirect". The second mode adds two OpenTofu variables, Traefik `exposedPort` branches, a container-hash branch, doctor and verify branches and a docs section. Switching between the modes needs a redeploy of 5 stacks.
    - **Fix:** Keep only the pf redirect. Public URLs are always on 443, and `dev-up` publishes `DEV_HTTPS_PORT -> 443` inside the node. Delete `public_https_port`, `public_http_port`, `DEV_PUBLIC_*` and `local.public_port`.
    - **If we skip it:** You keep about 60 lines and one more combination to test, for a mode nobody asked for.

13. **Escape hatches and compatibility code for setups that never existed** (`scripts/lib/openbao.sh:L87-90`, `scripts/cluster/host-install.sh:L44`, `scripts/cluster/dev-up.sh:L85-89`)
    - **What this is:** `OPENBAO_TOFU_ROOT=1` gives OpenTofu the root token again. `K3S_ARCH:-amd64` exists for "bundles built before K3S_ARCH existed". The config hash is only extended "so existing nodes keep their hash".
    - **Problem:** Test and prod have never been installed (earlier audits list them as UNVERIFIED), so there are no old bundles or old nodes to protect. `OPENBAO_TOFU_ROOT` is a one-variable way to undo the audit L7 fix.
    - **Fix:** Delete all three: `bundle_arch="${K3S_ARCH:?bundle.env lacks K3S_ARCH}"`, and always add the port mapping to `cfg_sum`.
    - **If we skip it:** Dead branches that someone will one day "use" in prod.

## Nice to have

14. **Fixed temp file names for cosign errors** (`scripts/supply-chain/verify-signatures.sh:L30-33`, `scripts/supply-chain/sign.sh:L65-68`)
    - **What this is:** stderr goes to `/tmp/cosign.err` and `/tmp/cosign-verify.err`.
    - **Problem:** On Linux the scripts run as root, and two parallel runs overwrite each other's error text. With symlink protection off, a local user can plant a symlink there.
    - **Fix:** `err="$(mktemp)"` once per script, removed in the EXIT trap.
    - **If we skip it:** Confusing error messages, and a small local risk.

15. **The "state is encrypted" check looks at one stack only** (`scripts/verify.sh:L119-120`)
    - **What this is:** Verify proves encryption only for `tfstate-default-12-foundation-services`.
    - **Problem:** A stack written in plaintext, for example during a `STATE_READ_UNENCRYPTED` state move, would pass.
    - **Fix:** Loop over every Secret in `tofu-state` with the same jq test.
    - **If we skip it:** A plaintext state could stay unnoticed.

Verdict: The code is careful and portable, and lint is clean. Fix 1, 2 and 5 first: today a restore loses OpenBao data, one plan can wipe a namespace, and a site loss cannot be recovered. Then 3, 4 and 7, or the required macOS path fails on day one or weakens the laptop.

Lean: -95 lines, -0 dependencies possible (findings 8, 9, 12, 13). The pushback below adds about -480 lines and -1 Homebrew dependency.

Not checked: the dev cluster is not usable. The k3s container shows as "Up", but the API on 127.0.0.1:6443 refuses connections and the node's disk is 99% full, so no kubectl check was run. Not run, by your rules: `make plan`, deploy, verify and restore. Test/prod host paths and the whole macOS path were read only; they have never run on real hardware (the repo says so too). I skimmed and did not read line by line: `modules/{dagster,keycloak,polaris,trino,opa,rustfs,audit-archive}`, `scripts/lock-update.sh`, `scripts/release/publish.sh`, `scripts/airgap/solution.sh` and `scripts/dev/*`. Checks that passed: `make lint` (shellcheck, the Python unit tests, `tofu fmt`, `tofu validate` of all 11 stacks, the RustFS PDB render and lock consistency) and `make doctor ENV=dev` (OK with 2 warnings: a cgroup v1 host and 3 GB free disk). I left out 4 smaller findings.

## Ultra: pushback on scope

What the requirements justify and what to keep: the pf script, `machine-init`, the Brewfile and `macos-trust` are all asked for (rootful podman machine, Homebrew, a forwarded port plus pf). So are the per-architecture lock, the Zot mirror with digests, OpenBao/PKI, the policies, observability and backup. The list below covers what the stated need does not justify, with the smallest alternative for each.

- **Solution code in the IaC repo.** `scripts/dev/e2e.sh` (188 lines: runs Dagster jobs, erasure, masking), `scripts/dev/reset-lakehouse-data.sh` (63), `scripts/release/publish.sh` (109, builds the solution), and `uv` in the Brewfile ("tooling of the solution repository"). The owner wants the solution kept separate from the IaC. *Smallest:* move these to the solution repo and have them call this repo's `make verify`, `make sign` and `make solution-bundle`. Here, keep only platform checks (`verify.d/*`). That is about -360 lines and -1 Brewfile entry.
- **Multi-architecture copies in one Zot (`MIRROR_ARCHES`, `<tag>-<arch>` tags, `BUNDLE_TOOL_PLATFORMS`).** Every cluster has one architecture (mixed clusters are refused) and every environment has its own Zot, so nothing ever pulls `<tag>-arm64`. *Smallest:* the architecture is always `CLUSTER_ARCH`. Delete the extra-arch tag branch in `image_zot_tag`, the `arches` loop and `BUNDLE_TOOL_PLATFORMS`, about -30 lines plus docs. Add it back if test and prod ever really differ in architecture.
- **State backend in Kubernetes Secrets.** Encrypted state no longer compresses, so the 1 MiB Secret limit drives the architecture: stack 12 was split for size, there are size guards in both `tofu.sh` and `verify.sh`, and the state dies with the cluster (finding 5). *Smallest:* for test/prod, use OpenTofu's `s3` backend with `use_lockfile = true` on the off-cluster S3 target that the off-site copy already needs. For dev, use the `local` backend in `~/.boccob/dev`. Encryption stays as it is, and the size guards and the DR gap go away. If the team keeps Secrets, finding 5 is the minimum.
- **Supply-chain hook framework** (`hooks/pre-mirror.d`, `hooks/post-mirror.d`, two flags per hook) for three fixed steps. *Smallest:* three direct calls (finding 9).
- **Modules used by exactly one stack.** 15 of the 29 modules are thin wrappers around a single `helm_release` (for example `cloudnative-pg`: 76 lines, 1 output), each with its own `versions.tf`, `outputs.tf` and README (about 570 lines of boilerplate). *Smallest:* stop adding README and outputs for single-use modules. Inline the trivial ones (`cloudnative-pg`, `cert-manager`, `external-secrets`, `kyverno`) into their stack. Keep modules that are reused: `namespace-baseline`, `external-secret`, `ingress-host`, `postgres-cluster`, `tls-certificate`, `java-truststore`, `generated-secret`, `s3-mirror`, `openbao-snapshot`.
- **Third dev path in the docs.** `docs/getting-started.md` Part B.3 ("k3s directly on the VM, advanced, untested") repeats the test/prod runbook for a case nobody asked for. *Smallest:* delete it and link `docs/runbook-bootstrap.md`, about -20 lines.
- **Audit reports in the code repo** (`docs/audit/`, 4 reports, about 600 lines). They are evidence for ISO 27001, not something that helps you change the code. *Smallest:* keep them in the ISMS evidence store and leave a one-line link.
- **Edge cases for platforms nobody targets.** `arch_or_die` has separate messages for 32-bit x86, 32-bit ARM and Rosetta, `podman-machine` on Linux is allowed but "untested", and doctor has an Intel-Mac warning. *Smallest:* one message, "supported: linux amd64/arm64, macOS arm64", and refuse `podman-machine` on Linux. About -15 lines.
