#!/usr/bin/env bash
# dev only: remove ALL lakehouse data so a new solution release can start from
# scratch (needed when a release changes table schemas of incremental models).
#   1. drop every view, table and schema of the four Trino/Polaris catalogs
#      (as svc-dagster; Iceberg drop with purge removes the data files)
#   2. delete every object version and delete marker left in the four
#      lakehouse buckets (S3 user lakehouse-purge, inside the code-location pod)
# Keys of the keystore are lost: never run this outside dev.
#
#   CONFIRM=dev scripts/dev/reset-lakehouse-data.sh dev
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
# shellcheck source=../lib/dataplane.sh
source "${REPO_ROOT}/scripts/lib/dataplane.sh"
require_cmd kubectl jq python3
[[ "$ENV" == "dev" ]] || die "dev only"
[[ "${CONFIRM:-}" == "$ENV" ]] || die "set CONFIRM=${ENV}: this deletes all lakehouse data of ${ENV}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ca="${tmp}/ca.crt"; dp_ca_file "$ca"
q() { dp_trino_sa svc-dagster "$ca" "$@"; }

for catalog in raw clean consolidated curated; do
  step "drop everything in catalog ${catalog}"
  while read -r schema; do
    [[ "$schema" == information_schema || "$schema" == system ]] && continue
    while IFS=$'\t' read -r name type; do
      if [[ "$type" == VIEW ]]; then q "drop view if exists ${catalog}.${schema}.\"${name}\"" >/dev/null
      else q "drop table if exists ${catalog}.${schema}.\"${name}\"" >/dev/null; fi
    done < <(q "select table_name, table_type from ${catalog}.information_schema.tables where table_schema = '${schema}'" | jq -r '@tsv')
    q "drop schema if exists ${catalog}.${schema}" >/dev/null
    log "dropped ${catalog}.${schema}"
  done < <(q "show schemas from ${catalog}" | jq -r '.[0]')
done

step "delete all object versions in the lakehouse buckets"
kubectl -n orchestration exec -i deploy/dagster-code-dagster-user-deployments-lakehouse -- python -I - <<'PY'
import os
import s3fs
from fsspec.asyn import sync

fs = s3fs.S3FileSystem(key=os.environ["PURGE_S3_ACCESS_KEY_ID"], secret=os.environ["PURGE_S3_SECRET_ACCESS_KEY"],
                       client_kwargs={"endpoint_url": os.environ["S3_ENDPOINT_URL"], "region_name": os.environ.get("S3_REGION", "us-east-1")})
for bucket in ("lakehouse-raw", "lakehouse-clean", "lakehouse-consolidated", "lakehouse-curated"):
    removed = 0
    while True:
        page = sync(fs.loop, fs._call_s3, "list_object_versions", Bucket=bucket, MaxKeys=1000)
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in page.get("Versions", []) + page.get("DeleteMarkers", [])]
        if not objs:
            break
        sync(fs.loop, fs._call_s3, "delete_objects", Bucket=bucket, Delete={"Objects": objs, "Quiet": True})
        removed += len(objs)
    print(f"{bucket}: {removed} object versions / delete markers removed")
PY
log "lakehouse data of ${ENV} reset"
