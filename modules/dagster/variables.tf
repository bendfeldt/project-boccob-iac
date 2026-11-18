variable "namespace" {
  description = "Namespace (convention: orchestration; needs secrets_access, allow_kube_api (run launcher) and the platform-ca ConfigMap)."
  type        = string
}

variable "charts" {
  description = "Charts from module.versions.charts: dagster (webserver, daemon) and user_deployments (dagster-user-deployments: the code location, separate release)."
  type = map(object({
    repository = string
    name       = string
    version    = string
  }))
}

variable "code_location_image" {
  description = "Digest-pinned image of the solution's code location: <registry>/<repo>@sha256:<digest> (dist/image/image.ref of the solution repository). Used by the code server, the run pods and the pool Job."
  type        = string
  validation {
    condition     = can(regex("^[^/]+/.+@sha256:[0-9a-f]{64}$", var.code_location_image))
    error_message = "code_location_image must be pinned by digest: <registry>/<repository>@sha256:<64 hex>."
  }
}

variable "system_image" {
  description = "Image of webserver and daemon (module.versions.images[\"dagster\"]: official dagster image in the chart's version; the code location image has no dagster-webserver)."
  type        = any
}

variable "images" {
  description = "Helper images from module.versions.images: postgres (pg_isready init container), busybox (code-server wait), python (pepper Job)."
  type        = map(any)
}

variable "code_location_name" {
  description = "Name of the code location (user deployment, Service and gRPC host)."
  type        = string
  default     = "lakehouse"
}

variable "code_location_module" {
  description = "Python module with the Definitions."
  type        = string
  default     = "orchestration.definitions"
}

variable "database" {
  description = "PostgreSQL run/event/schedule storage. `kv_path`: OpenBao KV path with username / password / dbname."
  type = object({
    host    = string
    port    = optional(number, 5432)
    kv_path = string
  })
}

variable "solution_env" {
  description = "Non-secret environment of the code location and run pods (platform contract section 2)."
  type        = map(string)
}

variable "solution_secrets" {
  description = "Secret environment variables: ENV_NAME => { kv_path, property } in OpenBao. Rendered into Secret `<code location>-env` by External Secrets."
  type = map(object({
    kv_path  = string
    property = string
  }))
}

variable "pepper_kv_path" {
  description = "OpenBao KV path of the pseudonymisation pepper. Created once (check-and-set 0) and never overwritten by this module."
  type        = string
  default     = "orchestration/pseudonym-pepper"
}

variable "openbao" {
  description = "OpenBao access of the pepper Job (kubernetes auth)."
  type = object({
    url          = string
    kv_mount     = optional(string, "kv")
    auth_backend = optional(string, "kubernetes")
  })
}

variable "pools" {
  description = "Dagster concurrency pools => limit (lakehouse_writer must be 1: single writer for erasure, maintenance and the keystore)."
  type        = map(number)
  default     = { lakehouse_writer = 1 }
}

variable "max_concurrent_runs" {
  description = "Queued run coordinator: runs in progress at once."
  type        = number
  default     = 4
}

variable "webserver_replicas" {
  description = "Webserver pods."
  type        = number
  default     = 1
}

variable "resources" {
  description = "Resources per component: webserver, daemon, code_location, run."
  type = map(object({
    requests = map(string)
    limits   = map(string)
  }))
  default = {
    webserver     = { requests = { cpu = "50m", memory = "320Mi" }, limits = { memory = "768Mi" } }
    daemon        = { requests = { cpu = "50m", memory = "320Mi" }, limits = { memory = "768Mi" } }
    code_location = { requests = { cpu = "20m", memory = "320Mi" }, limits = { memory = "768Mi" } }
    run           = { requests = { cpu = "100m", memory = "768Mi" }, limits = { memory = "2Gi" } }
  }
}

variable "run_ttl_seconds" {
  description = "Seconds a finished run Job (and its pod log) is kept."
  type        = number
  default     = 86400
}

variable "ca_configmap" {
  description = "ConfigMap in the namespace with the platform CA bundle (key ca.crt)."
  type        = string
  default     = "platform-ca"
}

variable "labels" {
  description = "Labels for the created objects."
  type        = map(string)
  default     = {}
}

variable "secret_stores" {
  description = "External Secrets stores for this module's secrets: { read, push, kind }. Pass module.ns_<x>.secret_stores (the namespace's own SecretStores, kv/<ns>/* + granted reads, stack 11 namespace_secret_stores); the default names are the namespace's own SecretStores."
  type = object({
    read = string
    push = string
    kind = string
  })
  default = { read = "openbao", push = "openbao-push", kind = "SecretStore" }
}

variable "job_secrets" {
  description = <<-EOT
    Secret environment for selected jobs only (e.g. the purge credential for
    erasure / retention / maintenance). name => { env = ENV_NAME => { kv_path,
    property }, jobs = Dagster job names }. Each entry becomes Secret
    `<code location>-<name>-env` (External Secrets), which is NOT given to the
    code server or to other runs: a job attaches it through its tag
    `dagster-k8s/config` = {"container_config": {"env_from": [{"secret_ref":
    {"name": "<secret>"}}]}}; the Secret name is in the environment variable
    `name_env` (default <NAME>_ENV_SECRET) of the code location and the runs.
    ValidatingAdmissionPolicies
    admit a Job or Pod in the namespace that references the Secret only when
    it carries the label dagster/job of a listed job and was created by the
    run launcher (Job: ServiceAccount `run_launcher_service_account`; Pod: the
    Job controller).
  EOT
  type = map(object({
    env = map(object({
      kv_path  = string
      property = string
    }))
    jobs     = list(string)
    name_env = optional(string)
  }))
  default = {}
}

variable "run_launcher_service_account" {
  description = "ServiceAccount that creates the run Jobs (the queued run coordinator launches every run from the daemon; the chart's ServiceAccount `dagster`)."
  type        = string
  default     = "dagster"
}

variable "compute_logs" {
  description = "Step logs (stdout/stderr) to S3 with dagster_aws S3ComputeLogManager (webserver/daemon image and the code location image must contain dagster-aws). bucket/prefix on the platform S3 endpoint; kv_path: OpenBao KV path with access-key / secret-key of an S3 user limited to that bucket (delivered as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY to webserver, daemon, code server and run pods). null = NoOpComputeLogManager (stdout only)."
  type = object({
    bucket       = string
    prefix       = optional(string, "dagster")
    endpoint_url = string
    region       = optional(string, "us-east-1")
    kv_path      = string
  })
  default = null
}
