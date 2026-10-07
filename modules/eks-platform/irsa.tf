# ---------------------------------------------------------------------------
# IRSA: one IAM role per controller, each trusting ONLY its own
# namespace/ServiceAccount through the cluster's OIDC provider. Neither the
# nodes nor any other pod can assume them.
# ---------------------------------------------------------------------------

locals {
  controllers = {
    aws_load_balancer_controller = "kube-system:aws-load-balancer-controller"
    external_dns                 = "kube-system:external-dns"
    cluster_autoscaler           = "kube-system:cluster-autoscaler"
    external_secrets             = "external-secrets:external-secrets"
  }
}

data "aws_iam_policy_document" "controller_assume" {
  for_each = local.controllers

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:${each.value}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  for_each           = local.controllers
  name               = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.controller_assume[each.key].json
}

# ----------------------- AWS Load Balancer Controller -----------------------
# No AWS-managed policy exists. lbc_iam_policy.json is the upstream
# kubernetes-sigs/aws-load-balancer-controller docs/install/iam_policy.json;
# re-sync it whenever you bump the chart.
resource "aws_iam_policy" "lbc" {
  name   = "${var.name_prefix}-aws-load-balancer-controller"
  policy = file("${path.module}/lbc_iam_policy.json")
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.controller["aws_load_balancer_controller"].name
  policy_arn = aws_iam_policy.lbc.arn
}

# ------------------------------- external-dns -------------------------------
# Write access is scoped to exactly the zones this stack owns. The List*
# actions do not support resource-level scoping.
data "aws_iam_policy_document" "external_dns" {
  statement {
    sid       = "ChangeRecordsInOwnZones"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [for z in var.route53_zone_ids : "arn:aws:route53:::hostedzone/${z}"]
  }
  statement {
    sid       = "ListZonesAndRecords"
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "external-dns"
  role   = aws_iam_role.controller["external_dns"].id
  policy = data.aws_iam_policy_document.external_dns.json
}

# ---------------------------- Cluster Autoscaler ----------------------------
# Describe* cannot be resource-scoped. Mutations are conditioned on the
# cluster-owned tag that only the general pool's ASG carries, so the
# autoscaler physically cannot resize the dedicated RAG node group.
data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid = "Describe"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "MutateOwnedGroupsOnly"
    actions   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "cluster-autoscaler"
  role   = aws_iam_role.controller["cluster_autoscaler"].id
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

# ----------------------------- External Secrets -----------------------------
# Read-only, and only under this stack's SSM path + the explicitly listed
# Secrets Manager secrets (the RDS-managed master secret).
data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid       = "ReadOwnSsmParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/${var.name_prefix}/*"]
  }

  dynamic "statement" {
    for_each = length(var.secrets_manager_arns) > 0 ? [1] : []
    content {
      sid       = "ReadListedSecrets"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = var.secrets_manager_arns
    }
  }

  statement {
    sid       = "DecryptWithPlatformKey"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "external-secrets"
  role   = aws_iam_role.controller["external_secrets"].id
  policy = data.aws_iam_policy_document.external_secrets.json
}
