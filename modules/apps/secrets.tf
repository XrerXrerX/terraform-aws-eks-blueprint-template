# ---------------------------------------------------------------------------
# Secrets: External Secrets Operator materializes Kubernetes Secrets from
#   - SSM Parameter Store  /<name_prefix>/<NAME>   (app secrets, Redis AUTH)
#   - Secrets Manager      RDS-managed master secret (DB credentials)
#
# Terraform only declares WHICH parameter maps to WHICH env var. It never
# reads a secret value, so none ends up in Terraform state or plan output.
#
# The SecretStores are namespaced (not ClusterSecretStores): only workloads
# in this namespace can reference them.
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "store_ssm" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "aws-ssm"
      namespace = local.ns
    }
    spec = {
      provider = {
        aws = {
          service = "ParameterStore"
          region  = var.aws_region
        }
      }
    }
  }
}

resource "kubernetes_manifest" "store_secretsmanager" {
  count = var.database != null ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "aws-secretsmanager"
      namespace = local.ns
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
        }
      }
    }
  }
}

# <app>-secrets : every ENV_VAR => SSM parameter in apps[*].secrets
resource "kubernetes_manifest" "app_secrets" {
  for_each = { for k, s in local.app_ssm_secrets : k => s if length(s) > 0 }

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${each.key}-secrets"
      namespace = local.ns
    }
    spec = {
      refreshInterval = var.secret_refresh_interval
      secretStoreRef = {
        kind = "SecretStore"
        name = kubernetes_manifest.store_ssm.manifest.metadata.name
      }
      target = {
        name           = "${each.key}-secrets"
        creationPolicy = "Owner"
      }
      data = [
        for env, param in each.value : {
          secretKey = env
          remoteRef = { key = "/${var.name_prefix}/${param}" }
        }
      ]
    }
  }
}

# <app>-db : DB_USERNAME / DB_PASSWORD from the RDS-managed secret
resource "kubernetes_manifest" "app_db" {
  for_each = local.db_apps

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${each.key}-db"
      namespace = local.ns
    }
    spec = {
      refreshInterval = var.secret_refresh_interval
      secretStoreRef = {
        kind = "SecretStore"
        name = kubernetes_manifest.store_secretsmanager[0].manifest.metadata.name
      }
      target = {
        name           = "${each.key}-db"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "DB_USERNAME"
          remoteRef = { key = var.database.master_secret_arn, property = "username" }
        },
        {
          secretKey = "DB_PASSWORD"
          remoteRef = { key = var.database.master_secret_arn, property = "password" }
        },
      ]
    }
  }
}
