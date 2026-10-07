variable "name_prefix" { type = string }
variable "aws_region" { type = string }

variable "namespace" {
  type        = string
  description = "Namespace for every stateless app."
}

variable "oidc_provider" { type = string }
variable "oidc_provider_arn" { type = string }

variable "vpc_cidr" {
  type        = string
  description = "ALB (target-type ip) reaches pods from inside the VPC; NetworkPolicy allows this range onto exposed ports only."
}

variable "kms_key_arn" {
  type        = string
  description = "Granted to apps that use the SSE-KMS buckets."
}

variable "apps" {
  type = map(object({
    image       = string
    port        = optional(number)
    exposure    = string
    hosts       = list(string) # FQDNs
    health_path = string

    autoscaling = object({
      min_replicas = number
      max_replicas = number
      cpu_target   = number
    })

    resources = object({
      cpu_request    = string
      memory_request = string
      memory_limit   = string
    })

    command = optional(list(string))
    args    = optional(list(string))
    env     = map(string)
    secrets = map(string)

    database   = bool
    redis      = bool
    s3_buckets = list(string)

    allow_from            = list(string)
    allow_from_namespaces = list(string)

    run_as_user               = number
    read_only_root_filesystem = bool
    writable_paths            = list(string)

    strategy                         = string
    termination_grace_period_seconds = number
    safe_to_evict                    = bool
    ingress_annotations              = map(string)
  }))
}

variable "ingress_annotations" {
  type        = map(map(string))
  description = "Base Ingress annotations per exposure (public, admin)."
}

variable "buckets" {
  type        = map(object({ name = string, arn = string }))
  description = "Bucket key => { name, arn }."
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

variable "pod_security_level" {
  type        = string
  default     = "restricted"
  description = "Pod Security Admission level enforced on the namespace."
}

variable "secret_refresh_interval" {
  type        = string
  default     = "1h"
  description = "How often External Secrets re-reads SSM / Secrets Manager. Rotation reaches the Secret within this window; pods pick it up on their next restart."
}

variable "default_container_limits" {
  type = object({
    cpu_request    = string
    memory_request = string
    memory_limit   = string
  })
  default = {
    cpu_request    = "100m"
    memory_request = "128Mi"
    memory_limit   = "512Mi"
  }
  description = "LimitRange defaults for any container that does not set its own."
}

variable "resource_quota" {
  type        = map(string)
  default     = {}
  description = "Optional namespace ResourceQuota hard limits, e.g. { \"requests.cpu\" = \"20\", \"limits.memory\" = \"64Gi\" }."
}
