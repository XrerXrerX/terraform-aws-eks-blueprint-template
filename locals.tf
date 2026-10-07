data "aws_caller_identity" "current" {}

locals {
  name_prefix  = "${var.project}-${var.environment}"
  cluster_name = "${local.name_prefix}-eks"
  account_id   = data.aws_caller_identity.current.account_id
  is_prod      = var.environment == "prod"

  common_tags = merge(var.extra_tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })

  eks_public_access_cidrs = coalesce(var.eks_public_access_cidrs, var.admin_allowed_cidrs)

  # Custom CloudWatch namespace for the RAG volume-usage metric (published by
  # the sidecar in the RAG pod, alarmed on in modules/observability).
  rag_metrics_namespace = "${var.project}/${var.environment}/rag"

  # ---------------------------------------------------------------- hostnames
  # Host label => FQDN. "" means the apex.
  app_hosts = {
    for k, a in var.apps : k => [
      for h in a.hosts : h == "" ? var.root_domain : "${h}.${var.root_domain}"
    ]
  }
  rag_hosts = var.rag.enabled ? [
    for h in var.rag.hosts : h == "" ? var.root_domain : "${h}.${var.root_domain}"
  ] : []

  # Every public/admin hostname is a SAN on ONE certificate whose primary name
  # is the apex. The apex itself is excluded here to avoid a perpetual diff.
  cert_sans = sort(distinct([
    for h in concat(flatten(values(local.app_hosts)), local.rag_hosts) : h if h != var.root_domain
  ]))

  # ------------------------------------------------------------------- images
  # Terraform sets these ONCE, at create time. CI owns them afterwards
  # (immutable git-SHA tags via `kubectl set image`), see modules/apps.
  app_images = {
    for k, a in var.apps : k => (
      a.image != null ? a.image : "${module.registry.repository_urls[a.ecr_repository]}:${coalesce(a.image_tag, var.image_tag)}"
    )
  }
  rag_image = var.rag.image != null ? var.rag.image : (
    var.rag.enabled ? "${module.registry.repository_urls[var.rag.ecr_repository]}:${coalesce(var.rag.image_tag, var.image_tag)}" : ""
  )

  # Resolved app definitions handed to modules/apps (adds image + FQDN hosts).
  apps = {
    for k, a in var.apps : k => merge(a, {
      image = local.app_images[k]
      hosts = local.app_hosts[k]
    })
  }

  # ------------------------------------------------------------------ secrets
  # Every SSM parameter any workload references. modules/secrets creates each
  # one as a placeholder; real values are written out-of-band (scripts/put-secrets.sh)
  # so no secret VALUE ever enters git, tfvars or Terraform state.
  secret_names = sort(distinct(concat(
    flatten([for a in var.apps : values(a.secrets)]),
    var.rag.enabled ? values(var.rag.secrets) : [],
  )))

  # ------------------------------------------------------------------ ingress
  # Two ALBs, created by the AWS Load Balancer Controller from Ingress groups:
  #   public — 0.0.0.0/0, for end-user traffic.
  #   admin  — admin_allowed_cidrs only, for operator surfaces.
  # They are separate on purpose: inbound-cidrs applies to the whole ALB
  # security group, so mixing groups would lock the public site to the admin
  # CIDRs (or open the admin tools to the world).
  ingress_group = {
    public = "${local.name_prefix}-public"
    admin  = "${local.name_prefix}-admin"
  }

  ingress_common_annotations = {
    "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"     = "ip"
    "alb.ingress.kubernetes.io/certificate-arn" = module.dns.certificate_arn
    "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    "alb.ingress.kubernetes.io/ssl-policy"      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    "alb.ingress.kubernetes.io/wafv2-acl-arn"   = module.waf.web_acl_arn
    # ALB-wide: must be identical on every Ingress of a group. 300s covers
    # slow LLM/RAG responses and long-lived WebSockets.
    "alb.ingress.kubernetes.io/load-balancer-attributes" = join(",", [
      "idle_timeout.timeout_seconds=300",
      "routing.http.drop_invalid_header_fields.enabled=true",
      "access_logs.s3.enabled=true",
      "access_logs.s3.bucket=${module.storage.alb_logs_bucket}",
      "access_logs.s3.prefix=alb",
    ])
    # Security headers are LISTENER attributes. Putting them in
    # load-balancer-attributes makes the controller fail and the ALB never
    # gets an address.
    "alb.ingress.kubernetes.io/listener-attributes.HTTPS-443" = join(",", [
      "routing.http.response.strict_transport_security.header_value=max-age=31536000;includeSubDomains",
      "routing.http.response.x_content_type_options.header_value=nosniff",
      "routing.http.response.x_frame_options.header_value=SAMEORIGIN",
    ])
  }

  ingress_annotations = {
    public = merge(local.ingress_common_annotations, {
      "alb.ingress.kubernetes.io/group.name"    = local.ingress_group.public
      "alb.ingress.kubernetes.io/inbound-cidrs" = "0.0.0.0/0"
    })
    admin = merge(local.ingress_common_annotations, {
      "alb.ingress.kubernetes.io/group.name"    = local.ingress_group.admin
      "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.admin_allowed_cidrs)
    })
  }
}
