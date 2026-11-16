# Exposes versions.lock.yaml to HCL. Every image/chart reference in a stack or
# module MUST come from here so that (a) nothing is pulled from the internet and
# (b) images are pinned by digest.

locals {
  lock = yamldecode(file("${path.module}/../../versions.lock.yaml"))

  images = {
    for key, img in local.lock.images : key => {
      # <registry>/<upstream registry>/<repo>
      repository = "${var.registry_host}/${img.source}"
      tag        = img.tag
      digest     = img.digest
      # full, digest-pinned reference for pod specs
      ref = "${var.registry_host}/${img.source}:${img.tag}@${img.digest}"
      # for charts that only expose `tag`: "<tag>@sha256:..." keeps the digest pin
      tag_digest = "${img.tag}@${img.digest}"
      # for charts that split registry and repository
      registry        = "${var.registry_host}/${split("/", img.source)[0]}"
      repository_path = join("/", slice(split("/", img.source), 1, length(split("/", img.source))))
    }
  }

  charts = {
    for key, chart in local.lock.charts : key => {
      repository = "oci://${var.registry_host}/charts"
      name       = chart.name
      version    = chart.version
    }
  }
}
