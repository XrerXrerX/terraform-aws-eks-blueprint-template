# ---------------------------------------------------------------------------
# One IAM role + ServiceAccount per app (IRSA). Each role trusts exactly one
# ServiceAccount, so a pod gets only its own AWS permissions — never the
# node's, never another app's. Apps with no AWS needs still get a role with
# NO policy: "this pod needs no AWS access" is then explicit and reviewable.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  for_each = var.apps

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${each.key}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  for_each           = var.apps
  name               = "${var.name_prefix}-app-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json
}

# S3: read/write on exactly the buckets the app lists, plus the KMS key those
# buckets are encrypted with.
data "aws_iam_policy_document" "s3" {
  for_each = { for k, a in var.apps : k => a if length(a.s3_buckets) > 0 }

  statement {
    sid       = "ListOwnBuckets"
    actions   = ["s3:ListBucket"]
    resources = [for b in each.value.s3_buckets : var.buckets[b].arn]
  }
  statement {
    sid       = "ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for b in each.value.s3_buckets : "${var.buckets[b].arn}/*"]
  }
  statement {
    sid       = "UseBucketKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "s3" {
  for_each = data.aws_iam_policy_document.s3
  name     = "s3"
  role     = aws_iam_role.app[each.key].id
  policy   = each.value.json
}

resource "kubernetes_service_account_v1" "app" {
  for_each = var.apps

  metadata {
    name      = each.key
    namespace = local.ns
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.app[each.key].arn
    }
    labels = { app = each.key }
  }

  # IRSA uses its own projected token volume, so the default API token is
  # not needed. Apps that call the Kubernetes API must opt in explicitly.
  automount_service_account_token = false
}
