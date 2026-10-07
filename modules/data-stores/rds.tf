# ---------------------------------------------------------------------------
# RDS (PostgreSQL or MySQL) in the ISOLATED subnets — no route to the
# internet, reachable only from the EKS node security group.
#
# Credentials: manage_master_user_password = true. RDS generates the master
# password, stores it in Secrets Manager (encrypted with the platform key) and
# can rotate it. Terraform never sees the value, so it is not in state.
# Pods receive it through External Secrets (modules/apps).
#
# The master user is for bootstrap only. Create one least-privilege database
# user per app (see docs/OPERATIONS.md) and move apps onto those.
# ---------------------------------------------------------------------------

locals {
  db_enabled = var.database.enabled
  is_pg      = var.database.engine == "postgres"
  db_port    = local.is_pg ? 5432 : 3306

  # postgres "16" -> postgres16 ; mysql "8.0" -> mysql8.0
  db_family = local.is_pg ? "postgres${split(".", var.database.engine_version)[0]}" : "mysql${join(".", slice(split(".", var.database.engine_version), 0, 2))}"

  db_parameters = local.is_pg ? {
    "rds.force_ssl"              = "1"    # reject non-TLS connections
    "log_min_duration_statement" = "1000" # log queries slower than 1s
    "log_connections"            = "1"
    "log_disconnections"         = "1"
    } : {
    "require_secure_transport" = "ON" # reject non-TLS connections
    "slow_query_log"           = "1"
    "long_query_time"          = "1"
    "character_set_server"     = "utf8mb4"
    "collation_server"         = "utf8mb4_unicode_ci"
  }

  db_log_exports = local.is_pg ? ["postgresql", "upgrade"] : ["error", "slowquery"]
}

resource "aws_security_group" "db" {
  count       = local.db_enabled ? 1 : 0
  name        = "${var.name_prefix}-db"
  description = "RDS - only from EKS nodes"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name_prefix}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_nodes" {
  count                        = local.db_enabled ? 1 : 0
  security_group_id            = aws_security_group.db[0].id
  description                  = "Database from EKS nodes/pods"
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
  referenced_security_group_id = var.node_security_group_id
}
# No egress rule: RDS never initiates connections.

resource "aws_db_subnet_group" "main" {
  count      = local.db_enabled ? 1 : 0
  name       = "${var.name_prefix}-db"
  subnet_ids = var.isolated_subnet_ids
  tags       = { Name = "${var.name_prefix}-db" }
}

resource "aws_db_parameter_group" "main" {
  count = local.db_enabled ? 1 : 0
  # name_prefix, not name: a major-version bump creates the new group before
  # destroying the old one (create_before_destroy), so names must not collide.
  name_prefix = "${var.name_prefix}-${replace(local.db_family, ".", "-")}-"
  family      = local.db_family

  dynamic "parameter" {
    for_each = local.db_parameters
    content {
      name         = parameter.key
      value        = parameter.value
      apply_method = "pending-reboot"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  count              = local.db_enabled ? 1 : 0
  name               = "${var.name_prefix}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count      = local.db_enabled ? 1 : 0
  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "main" {
  count = local.db_enabled ? 1 : 0

  identifier     = "${var.name_prefix}-db"
  engine         = var.database.engine
  engine_version = var.database.engine_version
  instance_class = var.database.instance_class

  allocated_storage     = var.database.allocated_storage_gb
  max_allocated_storage = var.database.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = var.database.db_name
  username = var.database.master_username
  port     = local.db_port

  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  iam_database_authentication_enabled = true

  multi_az               = var.database.multi_az
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.db[0].id]
  parameter_group_name   = aws_db_parameter_group.main[0].name
  publicly_accessible    = false

  backup_retention_period   = var.database.backup_retention_days
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.database.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-db-final"

  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring[0].arn
  enabled_cloudwatch_logs_exports = local.db_log_exports

  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = { Name = "${var.name_prefix}-db" }
}
