# ---------------------------------------------------------------------------
# Provider configuration
# ---------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  # Refuse to run against any account other than the one this stack is for.
  # Cheap insurance against an operator with the wrong AWS_PROFILE exported.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = local.common_tags
  }
}

# ---------------------------------------------------------------------------
# Kubernetes / Helm talk to the EKS cluster created by module.eks_cluster.
#
# `exec` auth fetches a short-lived token through the AWS CLI on every run, so
# there is no static kubeconfig or long-lived credential anywhere. Whoever runs
# `terraform apply` (operator or CI) only needs AWS CLI v2 and the same AWS
# credentials the aws provider uses.
#
# These providers cannot authenticate against a cluster that does not exist
# yet, which is why the first deploy is phased — see docs/DEPLOY.md.
# ---------------------------------------------------------------------------
provider "kubernetes" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", var.aws_region]
    }
  }
}
