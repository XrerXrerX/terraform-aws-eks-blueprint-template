output "namespace" {
  value = local.ns
}

output "service_name" {
  description = "In-cluster API address: http://<service_name>.<namespace>.svc.cluster.local:<port>."
  value       = kubernetes_service_v1.api.metadata[0].name
}

output "in_cluster_url" {
  value = "http://${kubernetes_service_v1.api.metadata[0].name}.${local.ns}.svc.cluster.local:${local.port}"
}

output "role_arn" {
  value = aws_iam_role.rag.arn
}
