locals {
  # Apps that listen on a port get a Service (and probes); workers do not.
  served = { for k, a in var.apps : k => a if a.port != null }

  # Apps with a public/admin hostname get an Ingress.
  exposed = { for k, a in local.served : k => a if a.exposure != "internal" && length(a.hosts) > 0 }

  # --------------------------------------------------------- runtime config
  # Non-secret connection facts are injected automatically; app-specific env
  # from var.apps wins on conflict.
  app_env = {
    for k, a in var.apps : k => merge(
      { AWS_REGION = var.aws_region },
      a.database && var.database != null ? {
        DB_HOST    = var.database.host
        DB_PORT    = tostring(var.database.port)
        DB_ENGINE  = var.database.engine
        DB_NAME    = var.database.name
        DB_SSLMODE = "require"
      } : {},
      a.redis && var.redis != null ? {
        REDIS_HOST = var.redis.host
        REDIS_PORT = tostring(var.redis.port)
        REDIS_TLS  = "true"
      } : {},
      { for b in a.s3_buckets : "S3_BUCKET_${upper(replace(b, "-", "_"))}" => var.buckets[b].name },
      a.env,
    )
  }

  # SSM-backed secrets per app (ENV_VAR => parameter name). Redis AUTH is
  # added automatically for apps with redis = true.
  app_ssm_secrets = {
    for k, a in var.apps : k => merge(
      a.secrets,
      a.redis && var.redis != null ? { REDIS_PASSWORD = var.redis.auth_token_parameter } : {},
    )
  }

  # Apps that get the RDS-managed credentials (Secrets Manager).
  db_apps = { for k, a in var.apps : k => a if a.database && var.database != null }
}
