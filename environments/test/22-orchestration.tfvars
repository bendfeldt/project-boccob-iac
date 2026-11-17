# dagster_code_location_image = "registry.<env>.lakehouse.internal:5000/boccob/dagster-code-location@sha256:<digest>"   # required
schedules_enabled = true
# deep erasure verification: scan all layer buckets for remains after every erasure (slow, thorough)
solution_env = {
  ERASURE_VERIFY_STORAGE = "true"
}
