output "cluster_name" { value = module.eks.cluster_name }
output "cluster_arn" { value = module.eks.cluster_arn }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_certificate_authority_data" { value = module.eks.cluster_certificate_authority_data }

output "oidc_provider" {
  description = "OIDC issuer host/path, used in IRSA trust-policy conditions."
  value       = module.eks.oidc_provider
}

output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }

output "node_security_group_id" {
  description = "The only source allowed into RDS and Redis."
  value       = module.eks.node_security_group_id
}

output "rag_node_asg_name" {
  description = "Alarmed on: the group is fixed at 1, so any drop is an incident, not a scale-in."
  value       = var.rag_enabled ? module.eks.eks_managed_node_groups["rag"].node_group_autoscaling_group_names[0] : null
}
