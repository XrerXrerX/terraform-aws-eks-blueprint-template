# ===========================================================================
# Global
# ===========================================================================
variable "project" {
  type        = string
  description = "Short project name. Prefixes almost every resource name (<project>-<environment>-...)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be 2-21 chars of lowercase letters, digits and dashes, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Environment name. `prod` turns on the strict guard rails in validate.tf."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for every regional resource."
}

variable "allowed_account_ids" {
  type        = list(string)
  default     = null
  description = "If set, the aws provider refuses to run against any other account. Strongly recommended in prod."
}

variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags added to every AWS resource (cost center, owner, ...)."
}

# ===========================================================================
# Networking
# ===========================================================================
variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "VPC CIDR. Carved into public / private / isolated /20 subnets per AZ."

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid CIDR of /16 or larger (the subnet layout needs 12 /20 blocks)."
  }
}

variable "az_count" {
  type        = number
  default     = 3
  description = "Availability Zones to spread subnets across. 3 for prod, 2 is the minimum EKS accepts."

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  type        = bool
  default     = false
  description = "true = one shared NAT gateway (cheaper, single AZ point of failure). false = one per AZ."
}

variable "flow_logs_retention_days" {
  type        = number
  default     = 30
  description = "VPC Flow Logs retention in CloudWatch. 0 disables flow logs."
}

# ===========================================================================
# DNS / TLS / edge access
# ===========================================================================
variable "root_domain" {
  type        = string
  description = "Root domain every public hostname is derived from (e.g. example.com)."
}

variable "create_route53_zone" {
  type        = bool
  default     = false
  description = "true = create the hosted zone here (then delegate NS at your registrar). false = look up an existing zone."
}

variable "admin_allowed_cidrs" {
  type        = list(string)
  description = <<-EOT
    CIDRs allowed to reach every `exposure = "admin"` surface (internal tools,
    the RAG API/UI, dashboards). Operator / VPN egress only. No default on
    purpose; 0.0.0.0/0 is rejected in prod (validate.tf).
  EOT

  validation {
    condition     = length(var.admin_allowed_cidrs) > 0 && alltrue([for c in var.admin_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_allowed_cidrs needs at least one valid CIDR (e.g. 203.0.113.10/32)."
  }
}

# ===========================================================================
# EKS
# ===========================================================================
variable "kubernetes_version" {
  type        = string
  default     = "1.34"
  description = "Control plane version. Pin it, and check the EKS standard-support window before every bump."
}

variable "node_kubernetes_version" {
  type        = string
  default     = null
  description = "Node group version. null = same as kubernetes_version. May lag by one minor so the control plane can move first."
}

variable "eks_endpoint_public_access" {
  type        = bool
  default     = true
  description = "Expose the Kubernetes API publicly (still IAM-authenticated). false = private-only; then run Terraform/CI from inside the VPC."
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  default     = null
  description = "CIDRs allowed to reach the public Kubernetes API. null = admin_allowed_cidrs."
}

variable "eks_cluster_log_types" {
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
  description = "Control plane log types shipped to CloudWatch. audit + authenticator are the forensic minimum."
}

variable "eks_log_retention_days" {
  type        = number
  default     = 90
  description = "Retention for control plane and Container Insights logs."
}

variable "enable_container_insights" {
  type        = bool
  default     = true
  description = "Install the CloudWatch Observability add-on. Every pod/node alarm in modules/observability depends on it."
}

variable "cluster_admin_principal_arns" {
  type        = list(string)
  default     = []
  description = "IAM role/user ARNs granted cluster-admin through EKS Access Entries (e.g. an SSO admin role)."
}

variable "enable_cluster_creator_admin" {
  type        = bool
  default     = true
  description = "Give the identity running `terraform apply` cluster-admin. Needed for the kubernetes/helm providers unless that identity is in cluster_admin_principal_arns."
}

variable "general_node_group" {
  type = object({
    instance_types = optional(list(string), ["m6i.large"])
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = optional(number, 2)
    max_size       = optional(number, 6)
    desired_size   = optional(number, 3)
    disk_size_gb   = optional(number, 50)
  })
  default     = {}
  description = "Autoscaled pool for every stateless app. Cluster Autoscaler moves it between min and max."
}

variable "node_imds_hop_limit" {
  type        = number
  default     = 2
  description = <<-EOT
    IMDSv2 hop limit on nodes (IMDSv2 is always REQUIRED). 1 blocks non-hostNetwork
    pods from reaching the node's instance profile — the stronger setting — but the
    CloudWatch agent needs 2. Set 1 if enable_container_insights = false.
  EOT

  validation {
    condition     = contains([1, 2], var.node_imds_hop_limit)
    error_message = "node_imds_hop_limit must be 1 or 2."
  }
}

# ===========================================================================
# Dedicated RAG / stateful node (NOT part of the general pod pool)
# ===========================================================================
variable "rag" {
  type = object({
    enabled = optional(bool, true)

    # ---- the dedicated node ----
    node_instance_type = optional(string, "r6i.large")
    node_ami_type      = optional(string, "AL2023_x86_64_STANDARD") # AL2023_x86_64_NVIDIA for GPU
    node_disk_size_gb  = optional(number, 50)

    # ---- the workload ----
    namespace           = optional(string, "rag")
    ecr_repository      = optional(string, "rag-api") # key in var.ecr_repositories
    image               = optional(string)            # full image ref; overrides ecr_repository
    image_tag           = optional(string)
    api_port            = optional(number, 8000)
    health_path         = optional(string, "/healthz")
    worker_command      = optional(list(string)) # null = no worker container
    vector_db_image     = optional(string, "qdrant/qdrant:v1.15.5")
    data_volume_gb      = optional(number, 50)
    vector_volume_gb    = optional(number, 100)
    exposure            = optional(string, "admin") # admin | internal | public
    hosts               = optional(list(string), ["rag"])
    env                 = optional(map(string), {})
    secrets             = optional(map(string), {}) # ENV_VAR => SSM parameter name
    database            = optional(bool, false)
    redis               = optional(bool, false)
    artifacts_bucket    = optional(string)           # key in var.buckets
    allowed_client_apps = optional(list(string), []) # app keys (in apps namespace) allowed to call the API

    resources = optional(object({
      api_cpu       = optional(string, "500m")
      api_memory    = optional(string, "1Gi")
      api_limit     = optional(string, "2Gi")
      worker_cpu    = optional(string, "250m")
      worker_memory = optional(string, "512Mi")
      worker_limit  = optional(string, "1Gi")
      vector_cpu    = optional(string, "500m")
      vector_memory = optional(string, "1Gi")
      vector_limit  = optional(string, "4Gi")
    }), {})
  })
  default     = {}
  description = "Dedicated, tainted, NON-autoscaled node + StatefulSet for RAG / vector DB. See docs/ARCHITECTURE.md."

  validation {
    condition     = contains(["admin", "internal", "public"], var.rag.exposure)
    error_message = "rag.exposure must be admin, internal or public."
  }
}

variable "rag_backup_retention_days" {
  type        = number
  default     = 14
  description = "AWS Backup retention for the RAG EBS volumes. 0 disables the backup plan."
}

# ===========================================================================
# Applications (stateless, general node pool)
# ===========================================================================
variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Default tag for ECR-built images at CREATE time only. CI owns image tags afterwards (immutable git SHAs)."
}

variable "ecr_repositories" {
  type        = list(string)
  default     = ["web", "api", "worker", "rag-api"]
  description = "First-party ECR repositories (one per image you build). Created as <project>/<name>."
}

variable "apps_namespace" {
  type        = string
  default     = "apps"
  description = "Namespace for every stateless app."
}

variable "apps" {
  type = map(object({
    # Image: either an ECR repository key from var.ecr_repositories, or a full reference.
    ecr_repository = optional(string)
    image          = optional(string)
    image_tag      = optional(string)

    port        = optional(number)             # null = no Service / Ingress / probes (background worker)
    exposure    = optional(string, "internal") # public | admin | internal
    hosts       = optional(list(string), [])   # labels under root_domain; "" = apex
    health_path = optional(string, "/healthz")

    autoscaling = optional(object({
      min_replicas = optional(number, 2)
      max_replicas = optional(number, 4)
      cpu_target   = optional(number, 75)
    }), {})

    resources = optional(object({
      cpu_request    = optional(string, "100m")
      memory_request = optional(string, "128Mi")
      memory_limit   = optional(string, "512Mi")
    }), {})

    command = optional(list(string))
    args    = optional(list(string))
    env     = optional(map(string), {})
    secrets = optional(map(string), {}) # ENV_VAR => SSM parameter name (under /<project>-<env>/)

    database   = optional(bool, false)      # inject DB_* env + credentials
    redis      = optional(bool, false)      # inject REDIS_* env + AUTH token
    s3_buckets = optional(list(string), []) # keys in var.buckets this app may read/write

    allow_from            = optional(list(string), []) # other app keys allowed to call this app
    allow_from_namespaces = optional(list(string), []) # whole namespaces allowed to call this app

    run_as_user               = optional(number, 10001)
    read_only_root_filesystem = optional(bool, true)
    writable_paths            = optional(list(string), []) # extra emptyDir mounts (besides /tmp)

    strategy                         = optional(string, "RollingUpdate") # Recreate for singletons
    termination_grace_period_seconds = optional(number, 30)
    safe_to_evict                    = optional(bool, true)
    ingress_annotations              = optional(map(string), {})
  }))
  default     = {}
  description = "Every stateless app, keyed by name. See terraform.tfvars.example for a worked example."

  validation {
    condition     = alltrue([for k, a in var.apps : contains(["public", "admin", "internal"], a.exposure)])
    error_message = "apps[*].exposure must be public, admin or internal."
  }

  validation {
    condition     = alltrue([for k, a in var.apps : a.exposure == "internal" || (a.port != null && length(a.hosts) > 0)])
    error_message = "An app with exposure public/admin needs a port and at least one host."
  }

  validation {
    condition     = alltrue([for k, a in var.apps : (a.image != null) != (a.ecr_repository != null)])
    error_message = "Each app sets exactly one of image or ecr_repository."
  }

  validation {
    condition     = alltrue([for k, a in var.apps : can(regex("^[a-z][a-z0-9-]{0,40}$", k))])
    error_message = "App keys must be DNS-safe: lowercase letters, digits, dashes."
  }

  # Cross-variable checks (Terraform >= 1.9): fail at input time with a clear
  # message instead of an index error deep inside a module.
  validation {
    condition     = alltrue(flatten([for k, a in var.apps : [for b in a.s3_buckets : contains(keys(var.buckets), b)]]))
    error_message = "apps[*].s3_buckets references a bucket key that is not defined in var.buckets."
  }

  validation {
    condition     = alltrue([for k, a in var.apps : a.ecr_repository == null || contains(var.ecr_repositories, a.ecr_repository)])
    error_message = "apps[*].ecr_repository must be listed in var.ecr_repositories."
  }

  validation {
    condition     = alltrue(flatten([for k, a in var.apps : [for src in a.allow_from : contains(keys(var.apps), src)]]))
    error_message = "apps[*].allow_from references an unknown app key."
  }

  validation {
    condition     = alltrue([for k, a in var.apps : a.autoscaling.min_replicas >= 1 && a.autoscaling.max_replicas >= a.autoscaling.min_replicas])
    error_message = "apps[*].autoscaling needs 1 <= min_replicas <= max_replicas."
  }

  validation {
    condition     = alltrue([for k, a in var.apps : contains(["RollingUpdate", "Recreate"], a.strategy)])
    error_message = "apps[*].strategy must be RollingUpdate or Recreate."
  }
}

# ===========================================================================
# Data stores
# ===========================================================================
variable "database" {
  type = object({
    enabled                  = optional(bool, true)
    engine                   = optional(string, "postgres") # postgres | mysql
    engine_version           = optional(string, "16")
    instance_class           = optional(string, "db.t4g.medium")
    allocated_storage_gb     = optional(number, 50)
    max_allocated_storage_gb = optional(number, 200)
    multi_az                 = optional(bool, true)
    deletion_protection      = optional(bool, true)
    backup_retention_days    = optional(number, 14)
    db_name                  = optional(string, "app")
    master_username          = optional(string, "dbadmin")
  })
  default     = {}
  description = "Managed RDS instance. The master password is generated and held by RDS in Secrets Manager — never in Terraform state."

  validation {
    condition     = contains(["postgres", "mysql"], var.database.engine)
    error_message = "database.engine must be postgres or mysql."
  }
}

variable "redis" {
  type = object({
    enabled            = optional(bool, true)
    node_type          = optional(string, "cache.t4g.small")
    engine_version     = optional(string, "7.1")
    num_cache_clusters = optional(number, 2) # >1 = replica + automatic failover
  })
  default     = {}
  description = "ElastiCache Redis (TLS + AUTH, private subnets)."
}

variable "buckets" {
  type = map(object({
    versioning         = optional(bool, true)
    retention_days     = optional(number, 0) # 0 = keep forever
    glacier_after_days = optional(number, 0) # 0 = no transition
  }))
  default = {
    uploads   = { retention_days = 0, glacier_after_days = 90 }
    artifacts = { retention_days = 30, versioning = false }
  }
  description = "Application S3 buckets (SSE-KMS, TLS-only, no public access). An ALB access-log bucket is always created on top."
}

# ===========================================================================
# Edge protection (WAF)
# ===========================================================================
variable "waf_rate_rules" {
  type = list(object({
    name       = string
    limit      = number           # requests per IP per window (min 10)
    path       = optional(string) # null = every request
    constraint = optional(string, "STARTS_WITH")
  }))
  default = [
    { name = "global", limit = 2000 },
    { name = "auth", limit = 20, path = "/auth" },
    { name = "api-auth", limit = 20, path = "/api/auth" },
  ]
  description = "Per-IP rate-based block rules. Put tight limits on login paths."
}

variable "waf_body_inspection_excluded_hosts" {
  type        = list(string)
  default     = []
  description = "FQDNs that skip the Common/KnownBadInputs rule groups (e.g. a webhook host receiving XML that false-positives). Keep this list empty unless you have a measured reason."
}

variable "waf_rate_window_seconds" {
  type        = number
  default     = 300
  description = "WAF rate evaluation window: 60, 120, 300 or 600."
}

# ===========================================================================
# Observability
# ===========================================================================
variable "alert_emails" {
  type        = list(string)
  default     = []
  description = "Emails subscribed to the alert SNS topic. Each must confirm the subscription."
}

variable "enable_alb_alarms" {
  type        = bool
  default     = false
  description = "ALB 5xx/latency/unhealthy alarms. Leave false until the Load Balancer Controller has created the ALB, then set true (docs/DEPLOY.md)."
}

# ===========================================================================
# CI/CD (GitHub Actions -> AWS via OIDC, no static keys)
# ===========================================================================
variable "github_org" {
  type        = string
  default     = ""
  description = "GitHub org/user owning the app repos. Empty disables the CI/CD module."
}

variable "github_deploy_repos" {
  type        = map(string)
  default     = {}
  description = "Repo name => the ONE branch allowed to deploy (e.g. { api = \"main\" })."
}

variable "create_github_oidc_provider" {
  type        = bool
  default     = true
  description = "Create the account-wide GitHub OIDC provider. false = look up an existing one (only one may exist per account)."
}
