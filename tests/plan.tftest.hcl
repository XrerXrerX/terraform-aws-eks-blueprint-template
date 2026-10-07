# ---------------------------------------------------------------------------
# Offline plan tests: every provider is mocked, so these need NO cloud
# credentials and touch no account. They exercise the full module graph,
# variable validation and the guard rails in validate.tf.
#
#   terraform init -backend=false
#   terraform test -var-file=terraform.tfvars.example
# ---------------------------------------------------------------------------

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
      arn        = "arn:aws:iam::111111111111:user/test"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::111111111111:role/test"
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}

run "example_plans_cleanly" {
  command = plan

  assert {
    condition     = output.secret_parameter_prefix == "/myplatform-prod/"
    error_message = "Secrets must live under /<project>-<environment>/."
  }

  assert {
    condition     = contains(keys(output.service_urls), "rag")
    error_message = "RAG should be exposed in the example."
  }

  assert {
    condition     = !contains(keys(output.service_urls), "worker")
    error_message = "A worker without a port must not get a URL."
  }
}

run "prod_rejects_open_admin_cidr" {
  command = plan

  variables {
    admin_allowed_cidrs = ["0.0.0.0/0"]
  }

  # The open CIDR also falls through to the EKS API list, which the
  # public_kubernetes_api check warns about.
  expect_failures = [terraform_data.guard_rails, check.public_kubernetes_api]
}

run "rejects_unknown_bucket_reference" {
  command = plan

  variables {
    apps = {
      api = {
        ecr_repository = "api"
        port           = 3000
        s3_buckets     = ["does-not-exist"]
      }
    }
  }

  expect_failures = [var.apps]
}

run "rejects_bad_exposure" {
  command = plan

  variables {
    apps = {
      api = {
        ecr_repository = "api"
        port           = 3000
        exposure       = "everyone"
      }
    }
  }

  expect_failures = [var.apps]
}

run "rag_can_be_disabled" {
  command = plan

  variables {
    rag = {
      enabled = false
    }
  }

  assert {
    condition     = !contains(keys(output.service_urls), "rag")
    error_message = "Disabled RAG must not produce a URL."
  }
}
