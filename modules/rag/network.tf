# ---------------------------------------------------------------------------
# Who may reach the RAG pod:
#   - nobody, by default (default-deny ingress for the namespace)
#   - the ALB, on the API port only, when exposure != internal
#   - the apps listed in allowed_client_apps (from the apps namespace), on
#     the API port only
# The vector DB port (6333) is reachable from inside the pod only.
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

resource "kubernetes_network_policy_v1" "api" {
  count = local.exposed || length(var.config.allowed_client_apps) > 0 ? 1 : 0

  metadata {
    name      = "allow-clients-to-api"
    namespace = local.ns
  }
  spec {
    pod_selector {
      match_labels = { app = local.name }
    }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = local.exposed ? [var.vpc_cidr] : []
        content {
          ip_block {
            cidr = from.value
          }
        }
      }

      dynamic "from" {
        for_each = var.config.allowed_client_apps
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = var.apps_namespace }
          }
          pod_selector {
            match_labels = { app = from.value }
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = local.port
      }
    }
  }
}

# ------------------------------------------------------------------ ingress
resource "kubernetes_ingress_v1" "api" {
  count = local.exposed ? 1 : 0

  wait_for_load_balancer = false

  metadata {
    name      = "${local.name}-api"
    namespace = local.ns
    # Load-balancer attributes (incl. idle timeout) are ALB-wide and must be
    # identical on every Ingress in a group, so they are set once in the root
    # module (local.ingress_common_annotations), never overridden here.
    annotations = merge(var.ingress_annotations[var.config.exposure], {
      "alb.ingress.kubernetes.io/healthcheck-path" = var.config.health_path
      "alb.ingress.kubernetes.io/success-codes"    = "200-399"
    })
  }

  spec {
    ingress_class_name = "alb"

    dynamic "rule" {
      for_each = var.hosts
      content {
        host = rule.value
        http {
          path {
            path      = "/"
            path_type = "Prefix"
            backend {
              service {
                name = kubernetes_service_v1.api.metadata[0].name
                port {
                  number = local.port
                }
              }
            }
          }
        }
      }
    }
  }
}
