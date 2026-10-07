# ---------------------------------------------------------------------------
# RAG — the stateful AI workload, kept OUT of the general pod pool.
#
# One StatefulSet pod on the dedicated `rag` node (modules/eks-cluster):
#
#   api            your RAG service (retrieval / embeddings / LLM calls)
#   vector-db      Qdrant, reachable by the api on localhost:6333 only
#   worker         optional background ingestion (same image, other command)
#   volume-metrics publishes PVC fill % to CloudWatch (no built-in metric)
#
# WHY A DEDICATED NODE + STATEFULSET:
#   The vector index and the data directory live on ReadWriteOnce EBS
#   volumes: one writer, one node. The pod must not be rescheduled for
#   bin-packing, because detaching a volume from under a live vector DB is
#   how an index gets corrupted. So: fixed, tainted, non-autoscaled node;
#   safe-to-evict=false; no HPA; Retain volumes; daily AWS Backup snapshots.
#
# Its own namespace = its own Pod Security, NetworkPolicy and SecretStore
# boundary. Only the apps listed in allowed_client_apps can reach the API.
# ---------------------------------------------------------------------------

locals {
  name = "rag"
  port = var.config.api_port

  has_worker = var.config.worker_command != null
  exposed    = var.config.exposure != "internal" && length(var.hosts) > 0

  env = merge(
    {
      AWS_REGION    = var.aws_region
      VECTOR_DB_URL = "http://localhost:6333"
      DATA_DIR      = "/data"
    },
    var.config.artifacts_bucket != null ? { S3_BUCKET_ARTIFACTS = var.buckets[var.config.artifacts_bucket].name } : {},
    var.config.database && var.database != null ? {
      DB_HOST    = var.database.host
      DB_PORT    = tostring(var.database.port)
      DB_ENGINE  = var.database.engine
      DB_NAME    = var.database.name
      DB_SSLMODE = "require"
    } : {},
    var.config.redis && var.redis != null ? {
      REDIS_HOST = var.redis.host
      REDIS_PORT = tostring(var.redis.port)
      REDIS_TLS  = "true"
    } : {},
    var.config.env,
  )

  ssm_secrets = merge(
    var.config.secrets,
    var.config.redis && var.redis != null ? { REDIS_PASSWORD = var.redis.auth_token_parameter } : {},
  )
  use_db = var.config.database && var.database != null
}

# -------------------------------------------------------------- namespace
resource "kubernetes_namespace_v1" "rag" {
  metadata {
    name = var.config.namespace
    labels = {
      "app.kubernetes.io/managed-by"               = "terraform"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "elbv2.k8s.aws/pod-readiness-gate-inject"    = "enabled"
    }
  }
}

locals {
  ns = kubernetes_namespace_v1.rag.metadata[0].name
}

# ------------------------------------------------------------- identity
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.config.namespace}:${local.name}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rag" {
  name               = "${var.name_prefix}-rag"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "rag" {
  # PutMetricData cannot be resource-scoped; it is constrained to our own
  # metric namespace instead.
  statement {
    sid       = "PublishVolumeMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metrics_namespace]
    }
  }

  dynamic "statement" {
    for_each = var.config.artifacts_bucket != null ? [var.buckets[var.config.artifacts_bucket]] : []
    content {
      sid       = "ArtifactsBucket"
      actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = [statement.value.arn, "${statement.value.arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.config.artifacts_bucket != null ? [1] : []
    content {
      sid       = "UseBucketKey"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "rag" {
  name   = "rag"
  role   = aws_iam_role.rag.id
  policy = data.aws_iam_policy_document.rag.json
}

resource "kubernetes_service_account_v1" "rag" {
  metadata {
    name      = local.name
    namespace = local.ns
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.rag.arn
    }
  }
  automount_service_account_token = false
}

# -------------------------------------------------------------- config
resource "kubernetes_config_map_v1" "rag" {
  metadata {
    name      = "rag-env"
    namespace = local.ns
  }
  data = local.env
}
