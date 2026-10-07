output "default_storage_class_name" {
  value = kubernetes_storage_class_v1.gp3.metadata[0].name
}

output "rag_storage_class_name" {
  description = "Tagged for AWS Backup. Used by the RAG PVCs only."
  value       = kubernetes_storage_class_v1.gp3_rag.metadata[0].name
}

output "rag_backup_tag" {
  description = "EC2 tag the gp3-rag class stamps on its volumes; modules/backup selects on it."
  value       = local.rag_backup_tag
}

output "external_secrets_release" {
  description = "Workloads creating ExternalSecrets must wait for this (CRDs + webhook)."
  value       = helm_release.external_secrets.name
}
