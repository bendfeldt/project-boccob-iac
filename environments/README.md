# environments

| File | Purpose |
|---|---|
| `<env>/env.sh` | non-secret settings for the scripts: cluster name/mode, base domain, registry, OpenBao share counts, state-encryption mode |
| `<env>/common.tfvars` | variables shared by every stack (`ha`, `cluster_cidrs`) |
| `<env>/<stack>.tfvars` | sizing and options of one stack |

State backend (`TOFU_BACKEND` in `env.sh`) and encryption are configured by
`scripts/tofu.sh`; the state never lives in the cluster it manages:

- dev: backend `local`, `~/.boccob/dev/tofu/state/<stack>.tfstate` (lock file next to it)
- test/prod: backend `s3` on a bucket outside the cluster and site
  (`<prefix>/<env>/<stack>.tfstate`, `use_lockfile`); endpoint, bucket and
  credentials come from the operator's environment (`TOFU_STATE_S3_*`,
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`), see `test/env.sh`
- OpenTofu state + plan encryption (AES-GCM, key derived with PBKDF2), `enforced`
  - dev: passphrase generated into `~/.boccob/dev/tofu/state-passphrase` (0600)
  - test/prod: `STATE_ENCRYPTION=pbkdf2-env`, the operator exports
    `TOFU_STATE_PASSPHRASE` (>= 32 chars) from the key custody store

Never put secret values into tfvars: credentials are generated in the cluster
(`modules/generated-secret`) or by the operators and live in OpenBao.
