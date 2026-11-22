# dagster_code_location_image = "registry.<env>.lakehouse.internal:5000/boccob/dagster-code-location@sha256:<digest>"   # required
schedules_enabled = true
# Dagster OSS has no roles: whoever passes the UI login can launch any job with
# run config and tags, i.e. act with the svc-dagster identity and the purge
# credential. Operators only; data engineers use dev.
dagster_ui_groups = ["platform-admin"]
