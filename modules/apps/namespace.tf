# ---------------------------------------------------------------------------
# Namespace guard rails:
#   - Pod Security Admission `restricted`: rejects privileged pods, host
#     namespaces, root users, privilege escalation, missing seccomp, ...
#   - LimitRange: a container that forgets its resources still gets sane
#     requests and a memory limit (one leak cannot take down a node).
#   - Optional ResourceQuota: caps the whole namespace.
#   - default-deny ingress NetworkPolicy (network_policy.tf).
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "apps" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by"               = "terraform"
      "pod-security.kubernetes.io/enforce"         = var.pod_security_level
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/warn"            = "restricted"
      # LB Controller injects a readiness gate: a rollout only proceeds once
      # the new pod is healthy in the ALB target group.
      "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled"
    }
  }
}

locals {
  # Referencing the namespace through this local gives every resource below
  # its dependency edge for free.
  ns = kubernetes_namespace_v1.apps.metadata[0].name
}

resource "kubernetes_limit_range_v1" "defaults" {
  metadata {
    name      = "defaults"
    namespace = local.ns
  }
  spec {
    limit {
      type = "Container"
      default_request = {
        cpu    = var.default_container_limits.cpu_request
        memory = var.default_container_limits.memory_request
      }
      default = {
        memory = var.default_container_limits.memory_limit
      }
    }
  }
}

resource "kubernetes_resource_quota_v1" "apps" {
  count = length(var.resource_quota) > 0 ? 1 : 0

  metadata {
    name      = "apps"
    namespace = local.ns
  }
  spec {
    hard = var.resource_quota
  }
}
