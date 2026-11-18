# Solution artefact (published by the solution repository: make image-push)
dagster_code_location_image = "registry.dev.lakehouse.internal:5000/boccob/dagster-code-location@sha256:9d9fbfebcb2aa93662a261a6d9882b11135f0b7fc995e269887075a25343f1f4"
solution_env = {
  DBT_THREADS = "2"
}
# dev lake is tiny: whole-lake scan of every object version after each erasure
erasure_verify_storage = true
