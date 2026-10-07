output "namespace" {
  value = local.ns
}

output "service_names" {
  description = "App key => Kubernetes Service name (Container Insights `Service` dimension). Workers without a port are absent."
  value       = { for k, s in kubernetes_service_v1.app : k => s.metadata[0].name }
}

output "role_arns" {
  description = "Per-app IRSA role ARNs."
  value       = { for k, r in aws_iam_role.app : k => r.arn }
}
