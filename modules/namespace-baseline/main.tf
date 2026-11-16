locals {
  namespace = var.name
  labels = merge(var.labels, {
    "app.kubernetes.io/managed-by" = "opentofu"
    "boccob.io/baseline"           = "true"
  })
  ns_labels = merge(local.labels, {
    "pod-security.kubernetes.io/enforce"         = var.pod_security_level
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/audit"           = "restricted"
    "pod-security.kubernetes.io/audit-version"   = "latest"
    "pod-security.kubernetes.io/warn"            = "restricted"
    "pod-security.kubernetes.io/warn-version"    = "latest"
    "boccob.io/secrets-access"                   = tostring(var.secrets_access)
  })
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name   = var.name
    labels = local.ns_labels
  }
}

resource "kubernetes_labels" "existing" {
  count       = var.create_namespace ? 0 : 1
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = var.name
  }
  labels = local.ns_labels
}

locals {
  # everything below waits for the namespace
  ns = var.create_namespace ? kubernetes_namespace_v1.this[0].metadata[0].name : kubernetes_labels.existing[0].metadata[0].name
}

# --- default deny (ingress + egress) -------------------------------------------
resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "dns" {
  count = var.allow_dns ? 1 : 0
  metadata {
    name      = "allow-out-dns"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "same_namespace" {
  count = var.allow_same_namespace ? 1 : 0
  metadata {
    name      = "allow-same-namespace"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector {}
      }
    }
    egress {
      to {
        pod_selector {}
      }
    }
  }
}

# The API server is not a pod: allow its endpoint addresses (post-DNAT) and the
# `kubernetes` Service address (pre-DNAT), whichever the CNI evaluates.
data "kubernetes_endpoints_v1" "kube_api" {
  count = var.allow_kube_api ? 1 : 0
  metadata {
    name      = "kubernetes"
    namespace = "default"
  }
}

data "kubernetes_service_v1" "kube_api" {
  count = var.allow_kube_api ? 1 : 0
  metadata {
    name      = "kubernetes"
    namespace = "default"
  }
}

locals {
  kube_api_endpoint_ips = var.allow_kube_api ? distinct(flatten([
    for subset in data.kubernetes_endpoints_v1.kube_api[0].subset : [for address in subset.address : address.ip]
  ])) : []
  kube_api_endpoint_ports = var.allow_kube_api ? distinct(flatten([
    for subset in data.kubernetes_endpoints_v1.kube_api[0].subset : [for port in subset.port : port.port]
  ])) : []
}

resource "kubernetes_network_policy_v1" "kube_api" {
  count = var.allow_kube_api ? 1 : 0
  metadata {
    name      = "allow-out-kube-api"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      dynamic "to" {
        for_each = local.kube_api_endpoint_ips
        content {
          ip_block {
            cidr = "${to.value}/32"
          }
        }
      }
      dynamic "ports" {
        for_each = local.kube_api_endpoint_ports
        content {
          port     = tostring(ports.value)
          protocol = "TCP"
        }
      }
    }
    egress {
      to {
        ip_block {
          cidr = "${data.kubernetes_service_v1.kube_api[0].spec[0].cluster_ip}/32"
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "ingress_controller" {
  count = length(var.ingress_controller_ports) > 0 ? 1 : 0
  metadata {
    name      = "allow-in-ingress-controller"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.ingress_controller.namespace }
        }
        pod_selector {
          match_labels = var.ingress_controller.pod_labels
        }
      }
      dynamic "ports" {
        for_each = var.ingress_controller_ports
        content {
          port     = tostring(ports.value)
          protocol = "TCP"
        }
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "ingress_hosts" {
  count = var.allow_ingress_hosts ? 1 : 0
  metadata {
    name      = "allow-out-ingress-hosts"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.ingress_controller.namespace }
        }
        pod_selector {
          match_labels = var.ingress_controller.pod_labels
        }
      }
      dynamic "ports" {
        for_each = var.ingress_controller_entrypoint_ports
        content {
          port     = tostring(ports.value)
          protocol = "TCP"
        }
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "ingress" {
  for_each = { for rule in var.ingress_rules : rule.name => rule }
  metadata {
    name      = "allow-in-${each.key}"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    pod_selector {
      match_labels = each.value.pod_selector
    }
    policy_types = ["Ingress"]
    ingress {
      dynamic "from" {
        for_each = each.value.from_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
          dynamic "pod_selector" {
            for_each = length(each.value.from_pod_labels) > 0 ? [1] : []
            content {
              match_labels = each.value.from_pod_labels
            }
          }
        }
      }
      dynamic "from" {
        for_each = each.value.from_cidrs
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
      dynamic "ports" {
        for_each = each.value.ports
        content {
          port     = tostring(ports.value)
          protocol = each.value.protocol
        }
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "egress" {
  for_each = { for rule in var.egress_rules : rule.name => rule }
  metadata {
    name      = "allow-out-${each.key}"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    pod_selector {
      match_labels = each.value.pod_selector
    }
    policy_types = ["Egress"]
    egress {
      dynamic "to" {
        for_each = each.value.to_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = to.value }
          }
          dynamic "pod_selector" {
            for_each = length(each.value.to_pod_labels) > 0 ? [1] : []
            content {
              match_labels = each.value.to_pod_labels
            }
          }
        }
      }
      dynamic "to" {
        for_each = each.value.to_cidrs
        content {
          ip_block {
            cidr = to.value
          }
        }
      }
      dynamic "ports" {
        for_each = each.value.ports
        content {
          port     = tostring(ports.value)
          protocol = each.value.protocol
        }
      }
    }
  }
}

# --- quota / limits ------------------------------------------------------------
resource "kubernetes_resource_quota_v1" "this" {
  count = length(var.resource_quota) > 0 ? 1 : 0
  metadata {
    name      = "baseline"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    hard = var.resource_quota
  }
}

resource "kubernetes_limit_range_v1" "this" {
  count = var.limit_range == null ? 0 : 1
  metadata {
    name      = "baseline"
    namespace = local.ns
    labels    = local.labels
  }
  spec {
    limit {
      type            = "Container"
      default_request = var.limit_range.default_request
      default         = var.limit_range.default_limit
      max             = length(var.limit_range.max) > 0 ? var.limit_range.max : null
    }
  }
}

# --- trust ---------------------------------------------------------------------
resource "kubernetes_config_map_v1" "platform_ca" {
  count = var.ca_bundle_pem == null ? 0 : 1
  metadata {
    name      = "platform-ca"
    namespace = local.ns
    labels    = local.labels
  }
  data = {
    "ca.crt" = var.ca_bundle_pem
  }
}
