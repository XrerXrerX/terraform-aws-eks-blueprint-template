variable "name_prefix" { type = string }
variable "vpc_id" { type = string }

variable "isolated_subnet_ids" {
  type        = list(string)
  description = "No internet route. RDS lives here."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "ElastiCache subnet group."
}

variable "node_security_group_id" {
  type        = string
  description = "EKS node/pod security group — the ONLY source allowed to reach the database and Redis."
}

variable "kms_key_arn" { type = string }
variable "kms_key_id" { type = string }

variable "database" {
  type = object({
    enabled                  = bool
    engine                   = string
    engine_version           = string
    instance_class           = string
    allocated_storage_gb     = number
    max_allocated_storage_gb = number
    multi_az                 = bool
    deletion_protection      = bool
    backup_retention_days    = number
    db_name                  = string
    master_username          = string
  })
}

variable "redis" {
  type = object({
    enabled            = bool
    node_type          = string
    engine_version     = string
    num_cache_clusters = number
  })
}
