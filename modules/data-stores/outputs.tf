output "database" {
  description = "Connection facts for workloads (no credentials). null when disabled."
  value = local.db_enabled ? {
    host              = aws_db_instance.main[0].address
    port              = local.db_port
    engine            = var.database.engine
    name              = var.database.db_name
    master_secret_arn = aws_db_instance.main[0].master_user_secret[0].secret_arn
  } : null
}

output "db_master_secret_arn" {
  value = local.db_enabled ? aws_db_instance.main[0].master_user_secret[0].secret_arn : null
}

output "db_instance_id" {
  value = local.db_enabled ? aws_db_instance.main[0].identifier : null
}

output "redis" {
  description = "Connection facts for workloads (no credentials). null when disabled."
  value = local.redis_enabled ? {
    host                 = aws_elasticache_replication_group.redis[0].primary_endpoint_address
    port                 = 6379
    auth_token_parameter = "REDIS_AUTH_TOKEN" # under /<name_prefix>/
  } : null
}

output "redis_member_cluster_ids" {
  description = "Derived (<group>-001, -002, ...) rather than read from member_clusters, so alarms can for_each over them at plan time."
  value = local.redis_enabled ? [
    for i in range(var.redis.num_cache_clusters) : format("%s-redis-%03d", var.name_prefix, i + 1)
  ] : []
}
