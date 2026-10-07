variable "name_prefix" { type = string }
variable "aws_region" { type = string }
variable "account_id" { type = string }
variable "cluster_name" { type = string }

variable "kms_key_arn" {
  type        = string
  description = "Encrypts the SNS topic."
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "apps_namespace" { type = string }

variable "app_services" {
  type        = map(string)
  description = "App key => Kubernetes Service name."
}

variable "rag_enabled" { type = bool }
variable "rag_namespace" { type = string }

variable "rag_node_asg_name" {
  type    = string
  default = null
}

variable "rag_metrics_namespace" { type = string }

variable "db_instance_id" {
  type    = string
  default = null
}

variable "redis_cluster_ids" {
  type    = list(string)
  default = []
}

variable "enable_alb_alarms" {
  type    = bool
  default = false
}

variable "ingress_group_names" {
  type        = list(string)
  description = "Load Balancer Controller Ingress groups (one ALB each)."
}
