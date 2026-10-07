# ---------------------------------------------------------------------------
# ElastiCache Redis — private subnets, reachable only from EKS nodes,
# encrypted at rest (KMS) and in transit (TLS required), AUTH token on.
#
# num_cache_clusters > 1 adds a replica in another AZ with automatic failover.
#
# The AUTH token is generated here and stored in SSM. Unlike the RDS
# password it DOES live in Terraform state (ElastiCache has no managed-secret
# option) — which is one more reason the state bucket is KMS-encrypted,
# versioned and access-restricted (bootstrap/).
# ---------------------------------------------------------------------------

locals {
  redis_enabled = var.redis.enabled
  redis_ha      = var.redis.num_cache_clusters > 1
}

resource "aws_security_group" "redis" {
  count       = local.redis_enabled ? 1 : 0
  name        = "${var.name_prefix}-redis"
  description = "ElastiCache Redis - only from EKS nodes"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name_prefix}-redis" }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_nodes" {
  count                        = local.redis_enabled ? 1 : 0
  security_group_id            = aws_security_group.redis[0].id
  description                  = "Redis from EKS nodes/pods"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_elasticache_subnet_group" "redis" {
  count      = local.redis_enabled ? 1 : 0
  name       = "${var.name_prefix}-redis"
  subnet_ids = var.private_subnet_ids
}

resource "random_password" "redis_auth" {
  count   = local.redis_enabled ? 1 : 0
  length  = 48
  special = false # ElastiCache AUTH allows only a subset of specials
}

resource "aws_ssm_parameter" "redis_auth" {
  count  = local.redis_enabled ? 1 : 0
  name   = "/${var.name_prefix}/REDIS_AUTH_TOKEN"
  type   = "SecureString"
  key_id = var.kms_key_id
  value  = random_password.redis_auth[0].result
  tags   = { Name = "${var.name_prefix}-REDIS_AUTH_TOKEN" }
}

resource "aws_elasticache_replication_group" "redis" {
  count = local.redis_enabled ? 1 : 0

  replication_group_id = "${var.name_prefix}-redis"
  description          = "${var.name_prefix} cache / queue"
  engine               = "redis"
  engine_version       = var.redis.engine_version
  node_type            = var.redis.node_type
  port                 = 6379
  parameter_group_name = "default.redis7"

  num_cache_clusters         = var.redis.num_cache_clusters
  automatic_failover_enabled = local.redis_ha
  multi_az_enabled           = local.redis_ha

  subnet_group_name  = aws_elasticache_subnet_group.redis[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token                 = random_password.redis_auth[0].result

  snapshot_retention_limit   = 3
  snapshot_window            = "02:00-03:00"
  maintenance_window         = "sun:05:30-sun:06:30"
  auto_minor_version_upgrade = true

  tags = { Name = "${var.name_prefix}-redis" }
}
