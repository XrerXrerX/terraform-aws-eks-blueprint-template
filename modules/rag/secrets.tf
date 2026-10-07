# Same pattern as modules/apps: namespaced SecretStores + ExternalSecrets.
# Terraform never reads a secret value.

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
  count = local.use_db ? 1 : 0

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

resource "kubernetes_manifest" "secrets" {
  count = length(local.ssm_secrets) > 0 ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "rag-secrets"
      namespace = local.ns
    }
    spec = {
      refreshInterval = var.secret_refresh_interval
      secretStoreRef  = { kind = "SecretStore", name = "aws-ssm" }
      target          = { name = "rag-secrets", creationPolicy = "Owner" }
      data = [
        for env, param in local.ssm_secrets : {
          secretKey = env
          remoteRef = { key = "/${var.name_prefix}/${param}" }
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.store_ssm]
}

resource "kubernetes_manifest" "db" {
  count = local.use_db ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "rag-db"
      namespace = local.ns
    }
    spec = {
      refreshInterval = var.secret_refresh_interval
      secretStoreRef  = { kind = "SecretStore", name = "aws-secretsmanager" }
      target          = { name = "rag-db", creationPolicy = "Owner" }
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

  depends_on = [kubernetes_manifest.store_secretsmanager]
}
