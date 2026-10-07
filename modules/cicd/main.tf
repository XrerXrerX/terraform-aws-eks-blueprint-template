# ---------------------------------------------------------------------------
# GitHub Actions -> AWS via OIDC. No long-lived access keys anywhere.
#
# Each app repo's deploy workflow assumes ONE role that can:
#   - push images to this stack's ECR repositories (nothing else in ECR)
#   - describe the cluster (for `aws eks update-kubeconfig`)
#   - inside Kubernetes: get/list/watch/patch Deployments + StatefulSets in
#     the app namespaces ONLY (rbac.tf). It cannot create, delete, exec, read
#     Secrets, or touch any other namespace.
#
# Trust is pinned to <org>/<repo> on exactly ONE branch per repo.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # IAM no longer validates thumbprints for this provider (it uses its own
  # trusted CA list), but the API still requires a value.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Two subject formats exist: the classic repo:org/repo:ref:... and the
      # immutable-id form repo:org@ID/repo@ID:ref:... (opt-in / newer repos).
      # org, repo and branch stay exact in both.
      values = flatten([
        for repo, branch in var.github_deploy_repos : [
          "repo:${var.github_org}/${repo}:ref:refs/heads/${branch}",
          "repo:${var.github_org}@*/${repo}@*:ref:refs/heads/${branch}",
        ]
      ])
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name_prefix}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # account-wide by design; cannot be resource-scoped
  }

  statement {
    sid = "EcrPushPullOwnRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }

  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = [var.cluster_arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
