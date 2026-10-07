# ---------------------------------------------------------------------------
# One-time bootstrap: the S3 bucket that holds the MAIN stack's Terraform
# state. Run once per AWS account, with local state:
#
#   cd bootstrap
#   terraform init
#   terraform apply -var="state_bucket_name=<globally-unique-name>" -var="aws_region=<region>"
#
# Then copy the printed backend config into ../backend.hcl (git-ignored).
#
# Locking uses S3 native lockfiles (Terraform >= 1.10), so no DynamoDB table.
# The state contains infrastructure metadata and a few generated values
# (e.g. the Redis AUTH token): treat the bucket as sensitive.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

variable "aws_region" {
  type = string
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique bucket name, e.g. <org>-<project>-tfstate."
}

variable "state_admin_role_arns" {
  type        = list(string)
  default     = []
  description = "If set, ONLY these IAM principals (plus the account root) may read/write the state bucket."
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { ManagedBy = "terraform", Purpose = "terraform-state" }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "state" {
  description             = "Terraform state encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "state" {
  name          = "alias/terraform-state"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # every state revision is recoverable
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
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

  dynamic "statement" {
    for_each = length(var.state_admin_role_arns) > 0 ? [1] : []
    content {
      sid       = "OnlyStateAdmins"
      effect    = "Deny"
      actions   = ["s3:*"]
      resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "ArnNotLike"
        variable = "aws:PrincipalArn"
        values = concat(var.state_admin_role_arns, [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
        ])
      }
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

output "backend_hcl" {
  description = "Paste into ../backend.hcl (git-ignored), changing `key` per environment."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    key          = "<environment>/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
    use_lockfile = true
  EOT
}
