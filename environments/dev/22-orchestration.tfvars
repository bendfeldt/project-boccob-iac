# Solution artefact (published by the solution repository: make image-push)
dagster_code_location_image = "registry.dev.lakehouse.internal:5000/boccob/dagster-code-location@sha256:9d9fbfebcb2aa93662a261a6d9882b11135f0b7fc995e269887075a25343f1f4"
solution_env = {
  DBT_THREADS = "2"
}
# S3 compute logs need dagster-aws in the code location image: the deployed image
# above predates it (solution 0112d93). Set true together with the next image.
compute_logs_s3 = false
# dev lake is tiny: whole-lake scan of every object version after each erasure
erasure_verify_storage = "full"
