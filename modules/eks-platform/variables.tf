variable "name_prefix" { type = string }
variable "cluster_name" { type = string }
variable "aws_region" { type = string }
variable "account_id" { type = string }
variable "vpc_id" { type = string }

variable "oidc_provider" {
  type        = string
  description = "OIDC issuer host/path, used in IRSA trust conditions."
}

variable "oidc_provider_arn" { type = string }

variable "route53_zone_ids" {
  type        = list(string)
  description = "Every zone external-dns may write to — and nothing else."
}

variable "domain_filters" {
  type        = list(string)
  description = "external-dns --domain-filter, one per zone."
}

variable "kms_key_arn" {
  type        = string
  description = "Encrypts every dynamically provisioned EBS volume; decrypts SSM values for External Secrets."
}

variable "secrets_manager_arns" {
  type        = list(string)
  default     = []
  description = "Secrets Manager secrets External Secrets may read (in addition to the SSM path)."
}

variable "chart_versions" {
  type = object({
    aws_load_balancer_controller = optional(string, "1.14.0")
    external_dns                 = optional(string, "1.15.2")
    cluster_autoscaler           = optional(string, "9.53.0")
    external_secrets             = optional(string, "2.12.0")
    reloader                     = optional(string, "2.2.18")
  })
  default     = {}
  description = "Pinned Helm chart versions. cluster-autoscaler's minor must track kubernetes_version."
}

variable "enable_reloader" {
  type        = bool
  default     = true
  description = "Install Stakater Reloader so rotated secrets roll pods automatically."
}
