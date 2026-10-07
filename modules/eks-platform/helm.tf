# ---------------------------------------------------------------------------
# Cluster controllers, installed with Helm:
#
#   aws-load-balancer-controller  Ingress objects -> ALBs (+ WAF, TLS, logs)
#   external-dns                  Ingress hosts   -> Route53 records
#   cluster-autoscaler            Pending pods    -> more general nodes
#   external-secrets              SSM / Secrets Manager -> Kubernetes Secrets
#   reloader                      Secret/ConfigMap change -> rolling restart
#
# Every controller has its own IRSA role (irsa.tf) trusting only its own
# ServiceAccount. Chart versions are pinned; bump them deliberately together
# with kubernetes_version.
# ---------------------------------------------------------------------------

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_load_balancer_controller
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  # Passed explicitly so the controller never needs node IMDS.
  set {
    name  = "vpcId"
    value = var.vpc_id
  }
  set {
    name  = "replicaCount"
    value = "2"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.controller["aws_load_balancer_controller"].arn
  }

  depends_on = [aws_iam_role_policy_attachment.lbc]
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = var.chart_versions.external_dns
  namespace  = "kube-system"

  set {
    name  = "provider.name"
    value = "aws"
  }
  set {
    name  = "env[0].name"
    value = "AWS_DEFAULT_REGION"
  }
  set {
    name  = "env[0].value"
    value = var.aws_region
  }
  # A host outside every filter is skipped SILENTLY — no error, the record
  # just never appears. One entry per hosted zone.
  dynamic "set" {
    for_each = var.domain_filters
    content {
      name  = "domainFilters[${set.key}]"
      value = set.value
    }
  }
  set {
    name  = "txtOwnerId"
    value = var.cluster_name
  }
  # Never delete records it did not create.
  set {
    name  = "policy"
    value = "upsert-only"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.controller["external_dns"].arn
  }

  depends_on = [aws_iam_role_policy.external_dns]
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.chart_versions.cluster_autoscaler
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }
  set {
    name  = "extraArgs.expander"
    value = "least-waste"
  }
  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
  }
  # Do not churn nodes on brief dips.
  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = "10m"
  }
  set {
    name  = "extraArgs.scale-down-delay-after-add"
    value = "10m"
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.controller["cluster_autoscaler"].arn
  }

  depends_on = [aws_iam_role_policy.cluster_autoscaler]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_versions.external_secrets
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.controller["external_secrets"].arn
  }

  depends_on = [aws_iam_role_policy.external_secrets]
}

# Rolls Deployments annotated reloader.stakater.com/auto=true when a Secret or
# ConfigMap they use changes — so a secret rotated in SSM reaches running pods
# (via External Secrets' refresh) without a deploy. No AWS permissions.
resource "helm_release" "reloader" {
  count = var.enable_reloader ? 1 : 0

  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = var.chart_versions.reloader
  namespace        = "reloader"
  create_namespace = true

  set {
    name  = "reloader.readOnlyRootFileSystem"
    value = "true"
  }
}
