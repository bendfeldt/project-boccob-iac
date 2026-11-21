variable "registry_host" {
  description = "Zot registry host[:port] that holds the mirrored images and charts."
  type        = string
}

variable "arch" {
  description = "CPU architecture of the cluster nodes: amd64 (x64/x86_64) or arm64 (aarch64). Selects the per-platform digests of versions.lock.yaml."
  type        = string
  default     = "amd64"
  validation {
    condition     = contains(["amd64", "arm64"], var.arch)
    error_message = "arch must be amd64 (x64/x86_64) or arm64 (aarch64)."
  }
}
