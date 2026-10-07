variable "name_prefix" { type = string }
variable "cluster_name" { type = string }
variable "kubernetes_version" { type = string }

variable "node_version" {
  type        = string
  description = "Kubernetes version for the node groups. Independent of the control plane so it can lag one minor."
}

variable "vpc_id" { type = string }

variable "private_subnet_ids" {
  type        = list(string)
  description = "Nodes and pods live here."
}

variable "endpoint_public_access" { type = bool }

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  description = "Who may reach the public Kubernetes API endpoint (IAM still authenticates)."
}

variable "cluster_log_types" { type = list(string) }
variable "log_retention_days" { type = number }
variable "enable_container_insights" { type = bool }

variable "kms_key_arn" {
  type        = string
  description = "Envelope-encrypts Kubernetes Secrets and the log groups; granted to the EBS CSI driver."
}

variable "cluster_admin_principal_arns" {
  type    = list(string)
  default = []
}

variable "enable_cluster_creator_admin" {
  type    = bool
  default = true
}

variable "general_node_group" {
  type = object({
    instance_types = list(string)
    capacity_type  = string
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gb   = number
  })
}

variable "node_imds_hop_limit" {
  type    = number
  default = 2
}

variable "rag_enabled" { type = bool }

variable "rag_subnet_id" {
  type        = string
  description = "Single subnet for the dedicated RAG node. Its EBS volumes are AZ-bound, so the node must stay in one AZ."
}

variable "rag_node_instance_type" { type = string }
variable "rag_node_ami_type" { type = string }
variable "rag_node_disk_size_gb" { type = number }
