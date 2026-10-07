# ---------------------------------------------------------------------------
# Terraform & provider version constraints.
#
# Providers are pinned to a minor line; the exact build is recorded in
# .terraform.lock.hcl (commit that file in YOUR fork so every operator and CI
# run resolves the same provider binaries).
# ---------------------------------------------------------------------------
terraform {
  # 1.10+ for native S3 state locking (use_lockfile), no DynamoDB table needed.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend configuration: NOTHING environment-specific lives in git.
  # Create the bucket with ./bootstrap first, then:
  #   cp backend.hcl.example backend.hcl   # fill in, never commit
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}
