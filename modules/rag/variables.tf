variable "name_prefix" { type = string }
variable "aws_region" { type = string }
variable "cluster_name" { type = string }

variable "oidc_provider" { type = string }
variable "oidc_provider_arn" { type = string }
variable "vpc_cidr" { type = string }
variable "kms_key_arn" { type = string }

variable "storage_class_name" {
  type        = string
  description = "gp3-rag: encrypted, Retain, WaitForFirstConsumer, tagged for AWS Backup."
}

variable "metrics_namespace" {
  type        = string
  description = "CloudWatch namespace the volume-metrics sidecar publishes to."
}

variable "config" {
  description = "The resolved var.rag object from the root module."
  type = object({
    namespace           = string
    api_port            = number
    health_path         = string
    worker_command      = optional(list(string))
    vector_db_image     = string
    data_volume_gb      = number
    vector_volume_gb    = number
    exposure            = string
    env                 = map(string)
    secrets             = map(string)
    database            = bool
    redis               = bool
    artifacts_bucket    = optional(string)
    allowed_client_apps = list(string)
    resources = object({
      api_cpu       = string
      api_memory    = string
      api_limit     = string
      worker_cpu    = string
      worker_memory = string
      worker_limit  = string
      vector_cpu    = string
      vector_memory = string
      vector_limit  = string
    })
  })
}

variable "image" {
  type        = string
  description = "API/worker image (create-time only; CI owns it afterwards)."
}

variable "hosts" {
  type        = list(string)
  description = "FQDNs for the RAG API Ingress (ignored when exposure = internal)."
}

variable "ingress_annotations" {
  type = map(map(string))
}

variable "apps_namespace" {
  type        = string
  description = "Namespace of the stateless apps allowed (per allowed_client_apps) to call the RAG API."
}

variable "buckets" {
  type = map(object({ name = string, arn = string }))
}

variable "database" {
  type = object({
    host              = string
    port              = number
    engine            = string
    name              = string
    master_secret_arn = string
  })
  default = null
}

variable "redis" {
  type = object({
    host                 = string
    port                 = number
    auth_token_parameter = string
  })
  default = null
}

variable "aws_cli_image" {
  type        = string
  default     = "public.ecr.aws/aws-cli/aws-cli:2.17.20"
  description = "Pinned image for the volume-metrics sidecar (ECR Public: no Docker Hub rate limits)."
}

variable "run_as_user" {
  type    = number
  default = 1000
}

variable "secret_refresh_interval" {
  type    = string
  default = "1h"
}
