# ---------------------------------------------------------------------------
# In-cluster authorization for the deploy role: an EKS Access Entry maps it
# to the Kubernetes group `ci-deployers`, which is bound per namespace to a
# Role that can only roll workloads (`kubectl set image`, `rollout restart`,
# `rollout status`). Workload objects are created/destroyed by Terraform only.
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "deploy" {
  cluster_name      = var.cluster_name
  principal_arn     = aws_iam_role.deploy.arn
  kubernetes_groups = ["ci-deployers"]
  type              = "STANDARD"
}

resource "kubernetes_role_v1" "deploy" {
  for_each = toset(var.deploy_namespaces)

  metadata {
    name      = "ci-deployer"
    namespace = each.key
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
    verbs      = ["get", "list", "watch", "patch"]
  }
  # `kubectl rollout status` watches ReplicaSets / Pods.
  rule {
    api_groups = ["apps"]
    resources  = ["replicasets", "controllerrevisions"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "deploy" {
  for_each = toset(var.deploy_namespaces)

  metadata {
    name      = "ci-deployer"
    namespace = each.key
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deploy[each.key].metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "ci-deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}
