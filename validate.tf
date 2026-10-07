# ---------------------------------------------------------------------------
# Guard rails.
#
#   preconditions -> hard failures. Things that must never reach prod.
#   check blocks  -> warnings on every plan. Things that are legitimate in
#                    dev/staging but almost always a mistake in prod.
# ---------------------------------------------------------------------------

resource "terraform_data" "guard_rails" {
  lifecycle {
    precondition {
      condition = !local.is_prod || alltrue([
        for cidr in var.admin_allowed_cidrs : !contains(["0.0.0.0/0", "::/0"], cidr)
      ])
      error_message = "prod forbids 0.0.0.0/0 and ::/0 in admin_allowed_cidrs. Pin operator/VPN egress CIDRs."
    }

    precondition {
      condition     = !local.is_prod || !var.database.enabled || var.database.deletion_protection
      error_message = "prod requires database.deletion_protection = true."
    }

    # (Per-app reference checks live in variable "apps" validations.)
    precondition {
      condition     = !anytrue([for a in var.apps : a.database]) || var.database.enabled
      error_message = "An app sets database = true but var.database.enabled is false."
    }

    precondition {
      condition     = !anytrue([for a in var.apps : a.redis]) || var.redis.enabled
      error_message = "An app sets redis = true but var.redis.enabled is false."
    }

    precondition {
      condition     = !var.rag.enabled || var.rag.image != null || contains(var.ecr_repositories, var.rag.ecr_repository)
      error_message = "rag.ecr_repository must be listed in var.ecr_repositories (or set rag.image)."
    }
  }
}

check "prod_high_availability" {
  assert {
    condition     = !local.is_prod || !var.single_nat_gateway
    error_message = "WARNING: single_nat_gateway = true in prod — one AZ outage cuts egress for every node."
  }

  assert {
    condition     = !local.is_prod || !var.database.enabled || var.database.multi_az
    error_message = "WARNING: database.multi_az = false in prod — no automatic failover."
  }

  assert {
    condition     = !local.is_prod || !var.redis.enabled || var.redis.num_cache_clusters > 1
    error_message = "WARNING: redis.num_cache_clusters = 1 in prod — no replica, no automatic failover."
  }

  assert {
    condition     = !local.is_prod || var.az_count >= 3
    error_message = "WARNING: fewer than 3 AZs in prod."
  }

  assert {
    condition     = !local.is_prod || length(var.alert_emails) > 0
    error_message = "WARNING: no alert_emails in prod — alarms fire into an SNS topic nobody reads."
  }

  assert {
    condition     = !local.is_prod || var.allowed_account_ids != null
    error_message = "WARNING: allowed_account_ids is unset in prod — nothing stops an apply against the wrong account."
  }
}

check "public_kubernetes_api" {
  assert {
    condition     = !var.eks_endpoint_public_access || !contains(local.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "WARNING: the Kubernetes API is reachable from 0.0.0.0/0. It is still IAM-authenticated, but prefer a self-hosted runner / VPN CIDR."
  }
}
