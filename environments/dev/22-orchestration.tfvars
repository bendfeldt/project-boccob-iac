# Solution artefact (published by the solution repository: make image-push)
dagster_code_location_image = "registry.dev.lakehouse.internal:5000/boccob/dagster-code-location@sha256:e59ed9bb05b80e7b46c707a647404a7409768a6ece3e6f29c3bdc86564ec2c4c"
solution_env = {
  DBT_THREADS = "2"
}
# dev lake is tiny: whole-lake scan of every object version after each erasure
erasure_verify_storage = "full"
