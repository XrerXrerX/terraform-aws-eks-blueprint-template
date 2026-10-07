# ---------------------------------------------------------------------------
# AWS Backup for the RAG EBS volumes (vector index + app data).
#
# Retain on the StorageClass only protects against PVC deletion. Snapshots
# protect against a corrupted index or a bad migration. Selection is by the
# tag the gp3-rag StorageClass stamps on every volume it provisions.
#
# Snapshots are crash-consistent. For an application-consistent copy, also
# schedule the vector DB's own snapshot API (docs/OPERATIONS.md).
# ---------------------------------------------------------------------------

resource "aws_backup_vault" "rag" {
  name        = "${var.name_prefix}-rag"
  kms_key_arn = var.kms_key_arn
}

resource "aws_backup_plan" "rag" {
  name = "${var.name_prefix}-rag-daily"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.rag.name
    schedule          = var.schedule
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.retention_days
    }
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name_prefix}-backup"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# The volumes are encrypted with the platform key; Backup must be able to use it.
data "aws_iam_policy_document" "kms" {
  statement {
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
      "kms:CreateGrant",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "kms" {
  name   = "kms"
  role   = aws_iam_role.backup.id
  policy = data.aws_iam_policy_document.kms.json
}

resource "aws_backup_selection" "rag" {
  name         = "${var.name_prefix}-rag-ebs"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.rag.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.selection_tag.key
    value = var.selection_tag.value
  }
}
