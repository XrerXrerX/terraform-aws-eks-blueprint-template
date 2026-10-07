# Ranges, not pins: a module states what it is compatible with; the root
# module (and .terraform.lock.hcl) decides the exact version.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.17, < 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38, < 3.0"
    }
  }
}
