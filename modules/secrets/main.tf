# ---------------------------------------------------------------------------
# Application secrets — SSM Parameter Store SecureStrings under
# /<name_prefix>/<NAME>, encrypted with the platform KMS key.
#
# Terraform creates each parameter with a PLACEHOLDER value and then ignores
# the value forever. The real value is written out-of-band
# (scripts/put-secrets.sh, the console, or your secret-rotation tooling), so:
#   - no secret value is ever in git, tfvars, plan output or Terraform state;
#   - a rotation in SSM is never reverted by the next apply.
#
# Pods receive the values through External Secrets Operator (modules/apps,
# modules/rag), which re-syncs on its refresh interval — rotation does not
# need a Terraform run.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "secret" {
  for_each = toset(var.secret_names)

  name        = "/${var.name_prefix}/${each.key}"
  description = "Managed out-of-band. Terraform only creates the placeholder."
  type        = "SecureString"
  key_id      = var.kms_key_id
  value       = "CHANGE_ME"

  lifecycle {
    ignore_changes = [value, description]
  }

  tags = { Name = "${var.name_prefix}-${each.key}" }
}
