# Solution artefact (published by the solution repository: make image-push)
dagster_code_location_image = "registry.dev.lakehouse.internal:5000/boccob/dagster-code-location@sha256:3b60dab661786b9ed3915d318610ff1f908e43db13ac41f2649ef91f69be6375"
solution_env = {
  DBT_THREADS = "2"
}
# dev lake is tiny: whole-lake scan of every object version after each erasure
erasure_verify_storage = "full"
