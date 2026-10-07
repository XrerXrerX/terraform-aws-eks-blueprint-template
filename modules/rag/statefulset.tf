resource "kubernetes_service_v1" "headless" {
  metadata {
    name      = "${local.name}-headless"
    namespace = local.ns
  }
  spec {
    cluster_ip = "None"
    selector   = { app = local.name }
    port {
      name = "http"
      port = local.port
    }
  }
}

resource "kubernetes_stateful_set_v1" "rag" {
  # Rollout health is checked by CI / kubectl. Waiting here would block the
  # first apply while secrets are still placeholders.
  wait_for_rollout = false

  metadata {
    name      = local.name
    namespace = local.ns
    labels    = { app = local.name }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }

  spec {
    replicas     = 1
    service_name = kubernetes_service_v1.headless.metadata[0].name

    selector {
      match_labels = { app = local.name }
    }

    # OrderedReady + a RWO volume: the old pod is fully gone before the new
    # one mounts the disk. The EBS CSI driver enforces this too — a volume
    # cannot attach to two nodes.
    pod_management_policy = "OrderedReady"
    update_strategy {
      type = "RollingUpdate"
    }

    template {
      metadata {
        labels = { app = local.name }
        annotations = {
          # Belt and braces on top of the fixed, untagged node group: never
          # let an autoscaler count this pod as evictable.
          "cluster-autoscaler.kubernetes.io/safe-to-evict" = "false"
          "checksum/config"                                = sha1(jsonencode(local.env))
        }
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.rag.metadata[0].name
        automount_service_account_token = false

        # Vector DBs flush on shutdown; do not SIGKILL them at 30s.
        termination_grace_period_seconds = 120

        # Only on the dedicated node, and tolerate the taint that keeps
        # everything else off it.
        node_selector = { role = "rag" }
        toleration {
          key      = "workload"
          operator = "Equal"
          value    = "rag"
          effect   = "NoSchedule"
        }

        security_context {
          run_as_non_root = true
          run_as_user     = var.run_as_user
          run_as_group    = var.run_as_user
          fs_group        = var.run_as_user
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # ---------------------------------------------------- [0] api
        container {
          name  = "api"
          image = var.image

          port {
            name           = "http"
            container_port = local.port
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.rag.metadata[0].name
            }
          }
          dynamic "env_from" {
            for_each = length(local.ssm_secrets) > 0 ? ["rag-secrets"] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }
          dynamic "env_from" {
            for_each = local.use_db ? ["rag-db"] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          startup_probe {
            http_get {
              path = var.config.health_path
              port = local.port
            }
            period_seconds    = 5
            failure_threshold = 60 # model / index warm-up can be slow
          }
          readiness_probe {
            http_get {
              path = var.config.health_path
              port = local.port
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = var.config.health_path
              port = local.port
            }
            period_seconds    = 30
            failure_threshold = 3
          }

          resources {
            requests = {
              cpu    = var.config.resources.api_cpu
              memory = var.config.resources.api_memory
            }
            limits = {
              memory = var.config.resources.api_limit
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = var.run_as_user
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        # ----------------------------------------------- [1] vector-db
        container {
          name  = "vector-db"
          image = var.config.vector_db_image

          port {
            name           = "qdrant"
            container_port = 6333
          }

          # The image's default snapshots dir is in the read-only layer; with
          # a non-root UID Qdrant would panic creating it.
          env {
            name  = "QDRANT__STORAGE__SNAPSHOTS_PATH"
            value = "/qdrant/storage/snapshots"
          }
          env {
            name  = "QDRANT__TELEMETRY_DISABLED"
            value = "true"
          }

          volume_mount {
            name       = "vectors"
            mount_path = "/qdrant/storage"
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = 6333
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/livez"
              port = 6333
            }
            period_seconds = 30
          }

          resources {
            requests = {
              cpu    = var.config.resources.vector_cpu
              memory = var.config.resources.vector_memory
            }
            limits = {
              memory = var.config.resources.vector_limit
            }
          }

          security_context {
            allow_privilege_escalation = false
            # Qdrant writes an init marker in its working dir.
            read_only_root_filesystem = false
            run_as_non_root           = true
            run_as_user               = var.run_as_user
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        # ------------------------------------------- [2] volume-metrics
        # Container Insights has no per-PVC usage metric, and a vector index
        # growing until its disk is full is the most likely way RAG breaks.
        # Mounts both volumes read-only and publishes their fill % every 5
        # minutes; modules/observability alarms at 80% / 90%.
        container {
          name  = "volume-metrics"
          image = var.aws_cli_image
          command = ["/bin/sh", "-c", replace(<<-EOT
            while true; do
              for entry in "data:/vol/data" "vectors:/vol/vectors"; do
                vol="$${entry%%:*}"; path="$${entry#*:}"
                pct="$(df -P "$path" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
                if [ -n "$pct" ]; then
                  aws cloudwatch put-metric-data \
                    --region "${var.aws_region}" \
                    --namespace "${var.metrics_namespace}" \
                    --metric-name VolumeUtilization \
                    --unit Percent --value "$pct" \
                    --dimensions ClusterName=${var.cluster_name},Volume="$vol" \
                    || echo "put-metric-data failed for $vol"
                fi
              done
              sleep 300
            done
          EOT
          , "\r", "")] # strip CRLF if this file was checked out on Windows

          env {
            name  = "HOME"
            value = "/tmp"
          }

          volume_mount {
            name       = "data"
            mount_path = "/vol/data"
            read_only  = true
          }
          volume_mount {
            name       = "vectors"
            mount_path = "/vol/vectors"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = var.run_as_user
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        # -------------------------------------------- [3] worker (optional)
        dynamic "container" {
          for_each = local.has_worker ? [1] : []
          content {
            name    = "worker"
            image   = var.image
            command = var.config.worker_command

            env_from {
              config_map_ref {
                name = kubernetes_config_map_v1.rag.metadata[0].name
              }
            }
            dynamic "env_from" {
              for_each = length(local.ssm_secrets) > 0 ? ["rag-secrets"] : []
              content {
                secret_ref {
                  name = env_from.value
                }
              }
            }
            dynamic "env_from" {
              for_each = local.use_db ? ["rag-db"] : []
              content {
                secret_ref {
                  name = env_from.value
                }
              }
            }

            volume_mount {
              name       = "data"
              mount_path = "/data"
            }
            volume_mount {
              name       = "tmp"
              mount_path = "/tmp"
            }

            resources {
              requests = {
                cpu    = var.config.resources.worker_cpu
                memory = var.config.resources.worker_memory
              }
              limits = {
                memory = var.config.resources.worker_limit
              }
            }

            security_context {
              allow_privilege_escalation = false
              read_only_root_filesystem  = true
              run_as_non_root            = true
              run_as_user                = var.run_as_user
              capabilities {
                drop = ["ALL"]
              }
            }
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = "1Gi"
          }
        }
      }
    }

    # App data (documents, artifacts, local state).
    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class_name
        resources {
          requests = { storage = "${var.config.data_volume_gb}Gi" }
        }
      }
    }

    # Vector index — separate volume so it can grow / be restored
    # independently of the app data.
    volume_claim_template {
      metadata {
        name = "vectors"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class_name
        resources {
          requests = { storage = "${var.config.vector_volume_gb}Gi" }
        }
      }
    }
  }

  # CI owns the first-party images (api [0], worker [3]). vector-db and
  # volume-metrics are third-party images Terraform keeps owning.
  # NOTE: volumeClaimTemplates are immutable in Kubernetes — resize by
  # patching the PVCs (docs/OPERATIONS.md), then update the size variables.
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].container[3].image,
      spec[0].volume_claim_template,
    ]
  }

  depends_on = [
    kubernetes_manifest.secrets,
    kubernetes_manifest.db,
  ]
}

resource "kubernetes_service_v1" "api" {
  metadata {
    name      = "${local.name}-api"
    namespace = local.ns
    labels    = { app = local.name }
  }
  spec {
    type     = "ClusterIP"
    selector = { app = local.name }
    port {
      name        = "http"
      port        = local.port
      target_port = local.port
    }
  }
}
