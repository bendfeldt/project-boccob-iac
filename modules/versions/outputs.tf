output "images" {
  description = "Map of logical image name => { repository, tag, digest, ref, tag_digest, registry, repository_path } pointing at the Zot mirror."
  value       = local.images
}

output "charts" {
  description = "Map of logical chart name => { repository (oci://<zot>/charts), name, version }."
  value       = local.charts
}

output "k3s_version" {
  description = "Pinned k3s version."
  value       = local.lock.k3s.version
}

output "arch" {
  description = "CPU architecture the image digests were selected for."
  value       = var.arch
}

output "missing_images" {
  description = "Image keys without a build for var.arch (not in `images`; a module that references one fails at plan time)."
  value       = local.missing
}
