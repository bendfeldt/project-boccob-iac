# dagster_code_location_image = "registry.<env>.lakehouse.internal:5000/boccob/dagster-code-location@sha256:<digest>"   # required
schedules_enabled = true
# no whole-lake scan per erasure request (O(size of the lake), blocks the writer
# pool); physical removal is proven by the periodic canary verification
# (docs/data-plane.md, "Erasure verification")
erasure_verify_storage = false
