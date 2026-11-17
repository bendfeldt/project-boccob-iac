# environments

| File | Purpose |
|---|---|
| `<env>/env.sh` | non-secret settings for the scripts: cluster name/mode, base domain, registry, OpenBao share counts, state-encryption mode |
| `<env>/common.tfvars` | variables shared by every stack (`ha`, `cluster_cidrs`) |
| `<env>/<stack>.tfvars` | sizing and options of one stack |

State backend and encryption are identical in every environment and are
configured by `scripts/tofu.sh` (not by files here):

- backend `kubernetes`: Secret `tfstate-default-<stack>` in namespace `tofu-state`
  of the target cluster (lock: Lease `lock-tfstate-default-<stack>`)
- OpenTofu state + plan encryption (AES-GCM, key derived with PBKDF2), `enforced`
  - dev: passphrase generated into `~/.boccob/dev/tofu/state-passphrase` (0600)
  - test/prod: `STATE_ENCRYPTION=pbkdf2-env`, the operator exports
    `TOFU_STATE_PASSPHRASE` (>= 32 chars) from the key custody store

Never put secret values into tfvars: credentials are generated in the cluster
(`modules/generated-secret`) or by the operators and live in OpenBao.
