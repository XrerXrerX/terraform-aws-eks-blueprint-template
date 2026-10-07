# ---------------------------------------------------------------------------
# What an operator or CI job needs after an apply. Nothing here is secret;
# credentials stay in SSM / Secrets Manager and are never output.
# ---------------------------------------------------------------------------

output "cluster_name" {
  value = module.eks_cluster.cluster_name
}

output "update_kubeconfig_command" {
  description = "Point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks_cluster.cluster_name} --region ${var.aws_region}"
}

output "cluster_endpoint" {
  value = module.eks_cluster.cluster_endpoint
}

output "route53_name_servers" {
  description = "Delegate these at your registrar if the zone was created here."
  value       = module.dns.name_servers
}

output "ecr_registry" {
  description = "Set as the ECR_REGISTRY variable in each app repo."
  value       = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = module.registry.repository_urls
}

output "github_deploy_role_arn" {
  description = "Set as AWS_DEPLOY_ROLE_ARN in each app repo."
  value       = try(module.cicd[0].deploy_role_arn, null)
}

output "secret_parameter_prefix" {
  description = "SSM path every app secret lives under. Fill values with scripts/put-secrets.sh."
  value       = "/${local.name_prefix}/"
}

output "secret_parameters" {
  description = "Parameters that must be filled before the apps can start."
  value       = module.secrets.parameter_names
}

output "database_endpoint" {
  value = try(module.data_stores.database.host, null)
}

output "database_master_secret_arn" {
  description = "Secrets Manager secret (managed + rotatable by RDS) holding the master credentials."
  value       = module.data_stores.db_master_secret_arn
}

output "s3_buckets" {
  value = merge(
    { for k, b in module.storage.buckets : k => b.name },
    { alb_logs = module.storage.alb_logs_bucket }
  )
}

output "alert_topic_arn" {
  value = module.observability.sns_topic_arn
}

output "service_urls" {
  value = merge(
    { for k, hosts in local.app_hosts : k => [for h in hosts : "https://${h}"] if length(hosts) > 0 },
    var.rag.enabled ? { rag = [for h in local.rag_hosts : "https://${h}"] } : {}
  )
}

output "nat_egress_ips" {
  description = "Source IPs your pods present to third parties (for partner allow-lists)."
  value       = module.network.nat_public_ips
}
