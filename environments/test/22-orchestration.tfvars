# dagster_code_location_image = "registry.<env>.lakehouse.internal:5000/boccob/dagster-code-location@sha256:<digest>"   # required
schedules_enabled = true
# scan only the object versions under the touched tables and the subject's raw
# files; no whole-lake scan per request (O(size of the lake), blocks the writer
# pool) - docs/data-plane.md, "Erasure verification"
erasure_verify_storage = "scoped"
