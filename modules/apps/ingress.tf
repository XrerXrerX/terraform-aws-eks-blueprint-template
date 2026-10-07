# ---------------------------------------------------------------------------
# Ingress — there is deliberately no aws_lb anywhere in this project. The AWS
# Load Balancer Controller watches these objects and owns the ALBs:
#
#   exposure = "public" -> group <prefix>-public, open to 0.0.0.0/0
#   exposure = "admin"  -> group <prefix>-admin,  admin_allowed_cidrs only
#   exposure = "internal" -> no Ingress at all; reachable in-cluster only
#
# target-type ip registers pod IPs directly (no kube-proxy hop). The
# namespace's pod-readiness-gate label makes rollouts wait until the new pod
# is healthy IN THE ALB, not just in Kubernetes — no 502s during deploys.
#
# external-dns writes the Route53 record for each host. wait_for_load_balancer
# is false: a brand-new ALB can take minutes to get an address.
# ---------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "app" {
  for_each = local.exposed

  wait_for_load_balancer = false

  metadata {
    name      = each.key
    namespace = local.ns
    labels    = { app = each.key }
    annotations = merge(
      var.ingress_annotations[each.value.exposure],
      {
        "alb.ingress.kubernetes.io/healthcheck-path"        = each.value.health_path
        "alb.ingress.kubernetes.io/success-codes"           = "200-399"
        "alb.ingress.kubernetes.io/target-group-attributes" = "deregistration_delay.timeout_seconds=30"
      },
      each.value.ingress_annotations,
    )
  }

  spec {
    ingress_class_name = "alb"

    dynamic "rule" {
      for_each = each.value.hosts
      content {
        host = rule.value
        http {
          path {
            path      = "/"
            path_type = "Prefix"
            backend {
              service {
                name = kubernetes_service_v1.app[each.key].metadata[0].name
                port {
                  number = each.value.port
                }
              }
            }
          }
        }
      }
    }
  }
}
