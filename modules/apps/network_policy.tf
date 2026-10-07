# ---------------------------------------------------------------------------
# NetworkPolicies (enforced by the VPC CNI — enableNetworkPolicy=true in
# modules/eks-cluster).
#
#   1. default-deny ingress for every pod in the namespace
#   2. exposed apps: allow the ALB (from the VPC CIDR) onto their port only
#   3. east-west: allow only the pairs declared in apps[*].allow_from /
#      allow_from_namespaces
#
# Egress stays open: apps need RDS, Redis, AWS APIs and third-party APIs, and
# those are guarded by security groups, TLS and auth. Tighten with an egress
# policy if your threat model needs it.
# Kubelet health probes are allowed by the CNI and need no rule.
# ---------------------------------------------------------------------------

resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny-ingress"
    namespace = local.ns
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "from_alb" {
  for_each = local.exposed

  metadata {
    name      = "allow-alb-to-${each.key}"
    namespace = local.ns
  }
  spec {
    pod_selector {
      match_labels = { app = each.key }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        ip_block {
          cidr = var.vpc_cidr
        }
      }
      ports {
        protocol = "TCP"
        port     = each.value.port
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "east_west" {
  for_each = {
    for k, a in local.served : k => a
    if length(a.allow_from) > 0 || length(a.allow_from_namespaces) > 0
  }

  metadata {
    name      = "allow-clients-to-${each.key}"
    namespace = local.ns
  }
  spec {
    pod_selector {
      match_labels = { app = each.key }
    }
    policy_types = ["Ingress"]
    ingress {
      dynamic "from" {
        for_each = each.value.allow_from
        content {
          pod_selector {
            match_labels = { app = from.value }
          }
        }
      }
      dynamic "from" {
        for_each = each.value.allow_from_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = each.value.port
      }
    }
  }
}
