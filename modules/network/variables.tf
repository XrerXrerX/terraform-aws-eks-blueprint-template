variable "name_prefix" { type = string }

variable "cluster_name" {
  type        = string
  description = "Subnets are tagged kubernetes.io/cluster/<name> so the Load Balancer Controller can discover them."
}

variable "aws_region" { type = string }
variable "vpc_cidr" { type = string }
variable "az_count" { type = number }
variable "single_nat_gateway" { type = bool }

variable "flow_logs_retention_days" {
  type        = number
  description = "0 disables VPC Flow Logs."
}

variable "kms_key_arn" {
  type        = string
  description = "Encrypts the flow-log group."
}

variable "interface_endpoints" {
  type        = list(string)
  default     = ["sts", "ecr.api", "ecr.dkr", "ssm", "secretsmanager", "logs"]
  description = "AWS services reached through private interface endpoints instead of NAT."
}
