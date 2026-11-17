locals {
  default_policies = {
    "restrict-image-registries"         = true
    "require-image-digest"              = true
    "disallow-latest-tag"               = true
    "require-run-as-non-root"           = true
    "require-read-only-root-filesystem" = true
    "require-requests-limits"           = true
  }
  exceptions = [for e in var.exceptions : {
    name          = e.name
    policies      = e.policies
    justification = e.justification
    expression = join(" && ", concat(
      ["object.metadata.namespace in ${jsonencode(e.namespaces)}"],
      length(e.name_prefixes) == 0 ? [] : ["${jsonencode(e.name_prefixes)}.exists(p, object.metadata.name.startsWith(p))"],
    ))
  }]
}

# The policies are custom resources of CRDs installed by Kyverno. Shipping
# them as a small local chart keeps them in the same stack as Kyverno
# (kubernetes_manifest would need the CRDs at plan time) and out of the state.
resource "helm_release" "policies" {
  name      = "boccob-policies"
  namespace = var.namespace
  chart     = "${path.module}/chart"
  timeout   = 300
  atomic    = true

  values = [yamlencode({
    registryPrefix     = "${var.registry_host}/"
    mode               = var.mode
    enforceLabel       = var.enforce_label
    failurePolicy      = var.failure_policy
    excludedNamespaces = var.excluded_namespaces
    policies           = merge(local.default_policies, var.policies)
    signature = {
      enabled    = length(var.signature_public_keys) > 0
      imageGlobs = coalesce(var.signature_image_globs, ["${var.registry_host}/boccob/*"])
      publicKeys = var.signature_public_keys
      mode       = coalesce(var.signature_mode, var.mode)
    }
    keyless = [for k in var.keyless_policies : {
      name          = k.name
      imageGlobs    = k.image_globs
      issuer        = k.issuer
      subjectRegExp = k.subject_regexp
      tufMirror     = k.tuf_mirror
      trustedRoot   = k.trusted_root
      mode          = k.mode
    }]
    exceptions         = local.exceptions
    exceptionNamespace = var.namespace
  })]
}
