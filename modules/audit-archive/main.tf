# Daily WORM archive of the audit trail.
# Container "export" (python, stdlib only, TLS verified against the platform
# CA) reads the previous UTC day of the Loki audit tenant page by page and
# writes NDJSON (ts, stream labels, line), gzip. Container "upload" (rc) waits
# for it and writes the archive + a manifest to a bucket created with S3 object
# lock (default retention on the bucket). Each manifest records the archive's
# sha256 and the sha256 of the previous day's manifest (hash chain): a missing
# or altered day is detectable.
#   s3://<bucket>/<prefix>/<YYYY-MM-DD>/audit.ndjson.gz
#   s3://<bucket>/<prefix>/<YYYY-MM-DD>/manifest.json
# Re-run a day with env ARCHIVE_DAY=YYYY-MM-DD (locked objects are never
# overwritten: a new version is added).
# (The rc image's wget is BusyBox and cannot verify a CA, hence python.)

locals {
  labels = merge(var.labels, { "app.kubernetes.io/name" = var.name, "app.kubernetes.io/component" = "audit" })
  common_env = {
    HOME          = "/tmp"
    SSL_CERT_FILE = "/etc/platform-ca/ca.crt"
  }
  export_env = {
    LOKI_URL    = var.loki_url
    LOKI_TENANT = var.tenant
    PAGE_SIZE   = tostring(var.page_size)
  }
  upload_env = {
    S3_SCHEME = split("://", var.s3.endpoint)[0]
    S3_HOST   = split("://", var.s3.endpoint)[1]
    S3_BUCKET = var.s3.bucket
    S3_PREFIX = var.s3.prefix
  }
  container_security = {
    allow_privilege_escalation = false
    read_only_root_filesystem  = true
    run_as_non_root            = true
  }
}

resource "kubernetes_config_map_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "export.py" = <<-PY
      import datetime, gzip, hashlib, json, os, ssl, sys, time, urllib.parse, urllib.request

      def main():
          day = os.environ.get("ARCHIVE_DAY") or (datetime.datetime.now(datetime.timezone.utc).date() - datetime.timedelta(days=1)).isoformat()
          start = int(datetime.datetime.fromisoformat(day + "T00:00:00+00:00").timestamp())
          cursor, end = start * 10**9, (start + 86400) * 10**9
          ctx = ssl.create_default_context(cafile=os.environ["SSL_CERT_FILE"])
          page, lines, pages = int(os.environ.get("PAGE_SIZE", "1000")), 0, 0
          with gzip.open("/work/audit.ndjson.gz", "wt", encoding="utf-8", compresslevel=9) as out:
              while True:
                  query = urllib.parse.urlencode({"query": '{service_name=~".+"}', "direction": "forward",
                                                  "limit": page, "start": cursor, "end": end})
                  req = urllib.request.Request(os.environ["LOKI_URL"] + "/loki/api/v1/query_range?" + query,
                                               headers={"X-Scope-OrgID": os.environ["LOKI_TENANT"]})
                  for attempt in range(5):
                      try:
                          with urllib.request.urlopen(req, context=ctx, timeout=120) as r:
                              data = json.load(r)["data"]["result"]
                          break
                      except Exception as e:  # noqa: BLE001 - retried, then fatal
                          if attempt == 4:
                              raise
                          print(f"retry after {e}", file=sys.stderr)
                          time.sleep(5 * (attempt + 1))
                  entries = sorted(((int(v[0]), s["stream"], v[1]) for s in data for v in s["values"]),
                                   key=lambda e: e[0])
                  for ts, labels, line in entries:
                      out.write(json.dumps({"ts": str(ts), "labels": labels, "line": line}, separators=(",", ":")) + "\n")
                  lines += len(entries)
                  pages += 1
                  if len(entries) < page:
                      break
                  cursor = entries[-1][0] + 1
          sha = hashlib.sha256(open("/work/audit.ndjson.gz", "rb").read()).hexdigest()
          json.dump({"day": day, "tenant": os.environ["LOKI_TENANT"], "lines": lines, "pages": pages,
                     "archive_sha256": sha}, open("/work/export.json", "w"))
          print(f"exported {day}: {lines} lines in {pages} pages, sha256 {sha}")

      try:
          main()
          open("/work/done", "w").close()
      except Exception as e:
          print(f"export failed: {e}", file=sys.stderr)
          open("/work/failed", "w").close()
          sys.exit(1)
    PY
    "upload.sh" = <<-SH
      set -eu
      i=0
      until [ -f /work/done ]; do
        [ -f /work/failed ] && { echo "export failed"; exit 1; }
        i=$((i + 1)); [ "$i" -lt 900 ] || { echo "timeout waiting for the export"; exit 1; }
        sleep 2
      done
      export RC_HOST_s3="$${S3_SCHEME}://$${AWS_ACCESS_KEY_ID}:$${AWS_SECRET_ACCESS_KEY}@$${S3_HOST}"
      day="$(jq -r .day /work/export.json)"
      base="s3/$${S3_BUCKET}/$${S3_PREFIX}"
      prev_day="$(date -u -d "@$(( $(date -u -d "$day 00:00:00" +%s) - 86400 ))" +%Y-%m-%d)"
      prev="none"
      if rc cat "$base/$prev_day/manifest.json" > /tmp/prev.json 2>/dev/null; then
        prev="$(sha256sum /tmp/prev.json | cut -d' ' -f1)"
      fi
      jq --arg prev "$prev" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {previous_manifest_sha256: $prev, created: $created}' /work/export.json > /tmp/manifest.json
      rc put --quiet --enc-s3 "$base/$day/audit.ndjson.gz" /work/audit.ndjson.gz "$base/$day/audit.ndjson.gz"
      rc put --quiet --enc-s3 "$base/$day/manifest.json" /tmp/manifest.json "$base/$day/manifest.json"
      echo "archived $day to $base/$day/ (previous manifest $prev)"
    SH
  }
}

resource "kubernetes_cron_job_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    schedule                      = var.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 172800
        template {
          metadata {
            labels = local.labels
          }
          spec {
            automount_service_account_token = false
            restart_policy                  = "Never"
            security_context {
              run_as_non_root = true
              run_as_user     = 65534
              run_as_group    = 65534
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }
            container {
              name    = "export"
              image   = var.images.python
              command = ["python", "-I", "/config/export.py"]
              dynamic "env" {
                for_each = merge(local.common_env, local.export_env)
                content {
                  name  = env.key
                  value = env.value
                }
              }
              resources {
                requests = var.resources.requests
                limits   = var.resources.limits
              }
              security_context {
                allow_privilege_escalation = local.container_security.allow_privilege_escalation
                read_only_root_filesystem  = local.container_security.read_only_root_filesystem
                run_as_non_root            = local.container_security.run_as_non_root
                capabilities {
                  drop = ["ALL"]
                }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
              volume_mount {
                name       = "config"
                mount_path = "/config"
              }
              volume_mount {
                name       = "platform-ca"
                mount_path = "/etc/platform-ca"
              }
            }
            container {
              name    = "upload"
              image   = var.images.rc
              command = ["sh", "/config/upload.sh"]
              dynamic "env" {
                for_each = merge(local.common_env, local.upload_env)
                content {
                  name  = env.key
                  value = env.value
                }
              }
              env {
                name = "AWS_ACCESS_KEY_ID"
                value_from {
                  secret_key_ref {
                    name = var.s3.credentials_secret
                    key  = "access_key_id"
                  }
                }
              }
              env {
                name = "AWS_SECRET_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = var.s3.credentials_secret
                    key  = "secret_access_key"
                  }
                }
              }
              resources {
                requests = var.resources.requests
                limits   = var.resources.limits
              }
              security_context {
                allow_privilege_escalation = local.container_security.allow_privilege_escalation
                read_only_root_filesystem  = local.container_security.read_only_root_filesystem
                run_as_non_root            = local.container_security.run_as_non_root
                capabilities {
                  drop = ["ALL"]
                }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
              volume_mount {
                name       = "config"
                mount_path = "/config"
              }
              volume_mount {
                name       = "platform-ca"
                mount_path = "/etc/platform-ca"
              }
            }
            volume {
              name = "work"
              empty_dir {
                size_limit = var.work_size
              }
            }
            volume {
              name = "tmp"
              empty_dir {
                size_limit = "64Mi"
              }
            }
            volume {
              name = "config"
              config_map {
                name = kubernetes_config_map_v1.this.metadata[0].name
              }
            }
            volume {
              name = "platform-ca"
              config_map {
                name = var.ca_configmap
              }
            }
          }
        }
      }
    }
  }
}
