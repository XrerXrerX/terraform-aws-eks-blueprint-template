# ---------------------------------------------------------------------------
# S3 buckets.
#
#   var.buckets  — application buckets: SSE-KMS (platform key, bucket keys
#                  on), owner-enforced (no ACLs), public access fully blocked,
#                  TLS-only, optional versioning + lifecycle.
#   alb_logs     — ALB access logs. SSE-S3, because ALB log delivery does not
#                  support SSE-KMS.
#
# Apps never get static keys: access is granted per app via IRSA
# (modules/apps), scoped to the bucket keys listed in apps[*].s3_buckets.
# ---------------------------------------------------------------------------

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  bucket_names = { for k, b in var.buckets : k => "${var.name_prefix}-${k}-${random_id.suffix.hex}" }
  alb_logs     = "${var.name_prefix}-alb-logs-${random_id.suffix.hex}"
}

# ------------------------------ app buckets --------------------------------
resource "aws_s3_bucket" "app" {
  for_each = var.buckets
  bucket   = local.bucket_names[each.key]
  tags     = { Name = local.bucket_names[each.key] }
}

resource "aws_s3_bucket_ownership_controls" "app" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.app[each.key].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "app" {
  for_each                = var.buckets
  bucket                  = aws_s3_bucket.app[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.app[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "app" {
  for_each = { for k, b in var.buckets : k => b if b.versioning }
  bucket   = aws_s3_bucket.app[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "app" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.app[each.key].id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "noncurrent-versions"
    status = each.value.versioning ? "Enabled" : "Disabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  dynamic "rule" {
    for_each = each.value.glacier_after_days > 0 ? [1] : []
    content {
      id     = "transition-to-glacier"
      status = "Enabled"
      filter {}
      transition {
        days          = each.value.glacier_after_days
        storage_class = "GLACIER"
      }
    }
  }

  dynamic "rule" {
    for_each = each.value.retention_days > 0 ? [1] : []
    content {
      id     = "expire"
      status = "Enabled"
      filter {}
      expiration {
        days = each.value.retention_days
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.app]
}

data "aws_iam_policy_document" "app" {
  for_each = var.buckets

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.app[each.key].arn,
      "${aws_s3_bucket.app[each.key].arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "app" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.app[each.key].id
  policy   = data.aws_iam_policy_document.app[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.app]
}

# -------------------------------- ALB logs ---------------------------------
resource "aws_s3_bucket" "alb_logs" {
  bucket        = local.alb_logs
  force_destroy = true # logs only; never blocks a teardown
  tags          = { Name = local.alb_logs }
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.alb_log_retention_days
    }
  }
}

data "aws_elb_service_account" "main" {}

data "aws_iam_policy_document" "alb_logs" {
  # Older regions deliver through the regional ELB account, newer ones through
  # the log-delivery service principal. Allowing both works everywhere.
  statement {
    sid       = "ElbAccountDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }
  statement {
    sid       = "LogDeliveryService"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.alb_logs.arn,
      "${aws_s3_bucket.alb_logs.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}
