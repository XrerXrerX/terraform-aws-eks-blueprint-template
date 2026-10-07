# ---------------------------------------------------------------------------
# One customer-managed KMS key for the platform: Kubernetes Secrets envelope
# encryption, SSM SecureStrings, RDS, ElastiCache, EBS volumes, S3 (SSE-KMS),
# ECR, CloudWatch Logs, SNS and AWS Backup.
#
# A single key keeps the key policy reviewable in one place. Split it per data
# class (e.g. a separate key for backups) if your compliance regime asks for it.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "key" {
  # Account root = "let IAM policies decide". Every IRSA role and service role
  # in this stack is granted the key through its own IAM policy.
  statement {
    sid       = "EnableIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  # CloudWatch Logs (VPC flow logs, EKS control plane, Container Insights)
  # cannot use IAM; it needs an explicit key-policy grant, scoped to log
  # groups in this account and region.
  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${var.account_id}:*"]
    }
  }

  # CloudWatch alarms publishing to the KMS-encrypted SNS alert topic.
  statement {
    sid       = "AllowCloudWatchAlarmsToSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} platform key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.key.json
  tags                    = { Name = "${var.name_prefix}-kms" }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}
