# ---------------------------------------------------------------------------
# One Deployment (+ ConfigMap, Service, HPA, PDB) per entry in var.apps,
# all on the GENERAL node pool. The stateful RAG workload is deliberately not
# here — it has its own dedicated node (modules/rag).
#
# Hardening on every pod (and enforced by Pod Security Admission anyway):
#   non-root UID/GID, no privilege escalation, ALL capabilities dropped,
#   seccomp RuntimeDefault, read-only root filesystem (writable emptyDirs
#   only where declared), no Kubernetes API token mounted.
#
# Every container has a memory LIMIT (a leak cannot take down its node) but no
# CPU limit (CPU limits throttle and hurt latency instead of shedding load).
#
# IMAGE + REPLICA OWNERSHIP — read before changing anything here:
#   Terraform sets the image ONCE, at create time. CI owns it afterwards
#   (immutable git-SHA tag + `kubectl set image`), and the HPA owns replicas.
#   lifecycle.ignore_changes below is what keeps an unrelated `terraform
#   apply` from rolling production back to the create-time tag or resetting
#   the replica count. Fixed-size apps: set min_replicas = max_replicas.
# ---------------------------------------------------------------------------

resource "kubernetes_config_map_v1" "app" {
  for_each = var.apps

  metadata {
    name      = "${each.key}-env"
    namespace = local.ns
    labels    = { app = each.key }
  }

  data = local.app_env[each.key]
}

resource "kubernetes_deployment_v1" "app" {
  for_each = var.apps

  # Rollout health is CI's job (kubectl rollout status). Waiting here would
  # block the very first apply: secrets are still placeholders until
  # scripts/put-secrets.sh has run, so pods may not be Ready yet.
  wait_for_rollout = false

  metadata {
    name      = each.key
    namespace = local.ns
    labels    = { app = each.key }
    annotations = {
      # Restart pods when their ConfigMap/Secret changes (if Reloader is
      # installed — modules/eks-platform installs it by default).
      "reloader.stakater.com/auto" = "true"
    }
  }

  spec {
    replicas = each.value.autoscaling.min_replicas

    selector {
      match_labels = { app = each.key }
    }

    strategy {
      type = each.value.strategy
      dynamic "rolling_update" {
        for_each = each.value.strategy == "RollingUpdate" ? [1] : []
        content {
          max_unavailable = "0"
          max_surge       = "1"
        }
      }
    }

    template {
      metadata {
        labels = { app = each.key }
        annotations = {
          "cluster-autoscaler.kubernetes.io/safe-to-evict" = tostring(each.value.safe_to_evict)
          # Roll pods when non-secret config changes.
          "checksum/config" = sha1(jsonencode(local.app_env[each.key]))
        }
      }

      spec {
        service_account_name             = kubernetes_service_account_v1.app[each.key].metadata[0].name
        automount_service_account_token  = false
        termination_grace_period_seconds = each.value.termination_grace_period_seconds
        node_selector                    = { role = "general" }

        security_context {
          run_as_non_root = true
          run_as_user     = each.value.run_as_user
          run_as_group    = each.value.run_as_user
          fs_group        = each.value.run_as_user
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Spread replicas across AZs and nodes so one failure cannot take the
        # whole app down. Soft constraints: a degraded cluster still schedules.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = each.key }
          }
        }

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_labels = { app = each.key }
                }
              }
            }
          }
        }

        container {
          name    = each.key
          image   = each.value.image
          command = each.value.command
          args    = each.value.args

          dynamic "port" {
            for_each = each.value.port != null ? [each.value.port] : []
            content {
              name           = "http"
              container_port = port.value
            }
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app[each.key].metadata[0].name
            }
          }

          dynamic "env_from" {
            for_each = length(local.app_ssm_secrets[each.key]) > 0 ? ["${each.key}-secrets"] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          dynamic "env_from" {
            for_each = contains(keys(local.db_apps), each.key) ? ["${each.key}-db"] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          resources {
            requests = {
              cpu    = each.value.resources.cpu_request
              memory = each.value.resources.memory_request
            }
            limits = {
              memory = each.value.resources.memory_limit
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = each.value.read_only_root_filesystem
            run_as_non_root            = true
            run_as_user                = each.value.run_as_user
            run_as_group               = each.value.run_as_user
            capabilities {
              drop = ["ALL"]
            }
          }

          # Probes only for apps that serve HTTP. startup_probe gives slow
          # boots (migrations, warm caches) up to 150s before liveness counts.
          dynamic "startup_probe" {
            for_each = each.value.port != null ? [1] : []
            content {
              http_get {
                path = each.value.health_path
                port = each.value.port
              }
              period_seconds    = 5
              failure_threshold = 30
            }
          }

          dynamic "readiness_probe" {
            for_each = each.value.port != null ? [1] : []
            content {
              http_get {
                path = each.value.health_path
                port = each.value.port
              }
              period_seconds    = 10
              failure_threshold = 3
            }
          }

          dynamic "liveness_probe" {
            for_each = each.value.port != null ? [1] : []
            content {
              http_get {
                path = each.value.health_path
                port = each.value.port
              }
              period_seconds    = 20
              failure_threshold = 3
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          dynamic "volume_mount" {
            for_each = each.value.writable_paths
            content {
              name       = "writable-${volume_mount.key}"
              mount_path = volume_mount.value
            }
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = "256Mi"
          }
        }

        dynamic "volume" {
          for_each = each.value.writable_paths
          content {
            name = "writable-${volume.key}"
            empty_dir {
              size_limit = "512Mi"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].replicas,                               # owned by the HPA
      spec[0].template[0].spec[0].container[0].image, # owned by CI
    ]
  }

  depends_on = [
    kubernetes_manifest.app_secrets,
    kubernetes_manifest.app_db,
  ]
}

resource "kubernetes_service_v1" "app" {
  for_each = local.served

  metadata {
    name      = each.key
    namespace = local.ns
    labels    = { app = each.key }
  }

  spec {
    type     = "ClusterIP"
    selector = { app = each.key }
    port {
      name        = "http"
      port        = each.value.port
      target_port = each.value.port
    }
  }
}

# autoscaling/v2: v1 has no `behavior`, so scale-down could not be damped.
resource "kubernetes_horizontal_pod_autoscaler_v2" "app" {
  for_each = var.apps

  metadata {
    name      = each.key
    namespace = local.ns
  }

  spec {
    min_replicas = each.value.autoscaling.min_replicas
    max_replicas = each.value.autoscaling.max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.app[each.key].metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = each.value.autoscaling.cpu_target
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = 60
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 60
        }
      }
      scale_down {
        stabilization_window_seconds = 300
        select_policy                = "Min"
        policy {
          type           = "Pods"
          value          = 1
          period_seconds = 120
        }
      }
    }
  }
}

# Limits voluntary disruption (node drains, Cluster Autoscaler scale-in) to
# one pod at a time. max_unavailable, not min_available: with
# min_available = 1 and a single replica, NO eviction would ever be allowed
# and node upgrades would hang.
resource "kubernetes_pod_disruption_budget_v1" "app" {
  for_each = var.apps

  metadata {
    name      = each.key
    namespace = local.ns
  }

  spec {
    max_unavailable = "1"
    selector {
      match_labels = { app = each.key }
    }
  }
}
