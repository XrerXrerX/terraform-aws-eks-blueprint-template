variable "name_prefix" { type = string }
variable "cluster_name" { type = string }
variable "cluster_arn" { type = string }

variable "ecr_repository_arns" {
  type        = list(string)
  description = "The only repositories the deploy role may push to."
}

variable "deploy_namespaces" {
  type        = list(string)
  description = "Namespaces whose workloads CI may roll."
}

variable "github_org" {
  type = string
}

variable "github_deploy_repos" {
  type        = map(string)
  description = "Repo name => the ONE branch allowed to assume the deploy role."

  validation {
    condition     = length(var.github_deploy_repos) > 0
    error_message = "github_deploy_repos must list at least one repo when the CI/CD module is enabled."
  }
}

variable "create_oidc_provider" {
  type        = bool
  description = "Only one GitHub OIDC provider may exist per account."
}
