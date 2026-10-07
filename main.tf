# ---------------------------------------------------------------------------
# Module wiring. Dependencies only flow downward:
#
#   kms ──┬─> secrets
#         ├─> network ──> eks-cluster ──> eks-platform ──┬─> apps
#         │                    │                         └─> rag
#         │                    └──> data-stores ───────────────^
#   storage / dns / registry / waf ────────────────────────────^
#   observability, backup, cicd hang off the above.
#
# The kubernetes/helm providers cannot reach a cluster that does not exist
# yet, so the FIRST deploy is phased (docs/DEPLOY.md / scripts/apply.sh):
#   1. -target=module.eks_cluster   (also pulls in network + kms)
#   2. -target=module.eks_platform  (controllers + External Secrets CRDs)
#   3. full apply
# ---------------------------------------------------------------------------

module "kms" {
  source = "./modules/kms"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  account_id  = local.account_id
}

module "secrets" {
  source = "./modules/secrets"

  name_prefix  = local.name_prefix
  kms_key_id   = module.kms.key_id
  secret_names = local.secret_names
}

module "network" {
  source = "./modules/network"

  name_prefix              = local.name_prefix
  cluster_name             = local.cluster_name
  aws_region               = var.aws_region
  vpc_cidr                 = var.vpc_cidr
  az_count                 = var.az_count
  single_nat_gateway       = var.single_nat_gateway
  flow_logs_retention_days = var.flow_logs_retention_days
  kms_key_arn              = module.kms.key_arn
}

module "storage" {
  source = "./modules/storage"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.key_arn
  buckets     = var.buckets
}

module "dns" {
  source = "./modules/dns"

  name_prefix = local.name_prefix
  root_domain = var.root_domain
  create_zone = var.create_route53_zone
  cert_sans   = local.cert_sans
}

module "registry" {
  source = "./modules/registry"

  name_prefix  = local.name_prefix
  project      = var.project
  repositories = var.ecr_repositories
  kms_key_arn  = module.kms.key_arn
}

module "waf" {
  source = "./modules/waf"

  name_prefix                    = local.name_prefix
  rate_rules                     = var.waf_rate_rules
  rate_window_seconds            = var.waf_rate_window_seconds
  body_inspection_excluded_hosts = var.waf_body_inspection_excluded_hosts
}

# ---------------------------------------------------------------------------
# Cluster + node pools. The whole-module depends_on network is deliberate:
# `-target=module.eks_cluster` would otherwise skip the NAT gateways and
# private routes (the cluster only consumes subnet IDs), and nodes in private
# subnets would never join.
# ---------------------------------------------------------------------------
module "eks_cluster" {
  source = "./modules/eks-cluster"

  name_prefix        = local.name_prefix
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version
  node_version       = coalesce(var.node_kubernetes_version, var.kubernetes_version)

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  endpoint_public_access       = var.eks_endpoint_public_access
  endpoint_public_access_cidrs = local.eks_public_access_cidrs
  cluster_log_types            = var.eks_cluster_log_types
  log_retention_days           = var.eks_log_retention_days
  enable_container_insights    = var.enable_container_insights
  kms_key_arn                  = module.kms.key_arn

  cluster_admin_principal_arns = var.cluster_admin_principal_arns
  enable_cluster_creator_admin = var.enable_cluster_creator_admin

  general_node_group  = var.general_node_group
  node_imds_hop_limit = var.node_imds_hop_limit

  rag_enabled            = var.rag.enabled
  rag_subnet_id          = module.network.private_subnet_ids[0] # EBS is AZ-bound: pin the node
  rag_node_instance_type = var.rag.node_instance_type
  rag_node_ami_type      = var.rag.node_ami_type
  rag_node_disk_size_gb  = var.rag.node_disk_size_gb

  depends_on = [module.network]
}

module "data_stores" {
  source = "./modules/data-stores"

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  isolated_subnet_ids = module.network.isolated_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids

  # The ONLY ingress source for the database and Redis.
  node_security_group_id = module.eks_cluster.node_security_group_id

  kms_key_arn = module.kms.key_arn
  kms_key_id  = module.kms.key_id
  database    = var.database
  redis       = var.redis
}

# ---------------------------------------------------------------------------
# Cluster controllers: Load Balancer Controller, external-dns, Cluster
# Autoscaler, External Secrets Operator, and the gp3 StorageClasses.
# ---------------------------------------------------------------------------
module "eks_platform" {
  source = "./modules/eks-platform"

  name_prefix  = local.name_prefix
  cluster_name = module.eks_cluster.cluster_name
  aws_region   = var.aws_region
  account_id   = local.account_id
  vpc_id       = module.network.vpc_id

  oidc_provider     = module.eks_cluster.oidc_provider
  oidc_provider_arn = module.eks_cluster.oidc_provider_arn

  route53_zone_ids = [module.dns.zone_id]
  domain_filters   = [var.root_domain]
  kms_key_arn      = module.kms.key_arn

  # What External Secrets may read: our SSM path + the RDS-managed secret.
  # (Decided on var.database.enabled so the list length is known at plan time.)
  secrets_manager_arns = var.database.enabled ? [module.data_stores.db_master_secret_arn] : []
}

module "apps" {
  source = "./modules/apps"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  namespace   = var.apps_namespace

  oidc_provider     = module.eks_cluster.oidc_provider
  oidc_provider_arn = module.eks_cluster.oidc_provider_arn
  vpc_cidr          = module.network.vpc_cidr
  kms_key_arn       = module.kms.key_arn

  apps                = local.apps
  ingress_annotations = local.ingress_annotations
  buckets             = module.storage.buckets
  database            = module.data_stores.database
  redis               = module.data_stores.redis

  # Ingresses are inert until the Load Balancer Controller runs, and
  # ExternalSecrets need the CRDs the platform module installs.
  depends_on = [module.eks_platform]
}

module "rag" {
  source = "./modules/rag"
  count  = var.rag.enabled ? 1 : 0

  name_prefix  = local.name_prefix
  aws_region   = var.aws_region
  cluster_name = module.eks_cluster.cluster_name

  oidc_provider     = module.eks_cluster.oidc_provider
  oidc_provider_arn = module.eks_cluster.oidc_provider_arn
  vpc_cidr          = module.network.vpc_cidr
  kms_key_arn       = module.kms.key_arn

  storage_class_name = module.eks_platform.rag_storage_class_name
  metrics_namespace  = local.rag_metrics_namespace

  config              = var.rag
  image               = local.rag_image
  hosts               = local.rag_hosts
  ingress_annotations = local.ingress_annotations
  apps_namespace      = module.apps.namespace
  buckets             = module.storage.buckets
  database            = module.data_stores.database
  redis               = module.data_stores.redis

  depends_on = [module.eks_platform]
}

module "observability" {
  source = "./modules/observability"

  name_prefix  = local.name_prefix
  aws_region   = var.aws_region
  account_id   = local.account_id
  cluster_name = module.eks_cluster.cluster_name
  kms_key_arn  = module.kms.key_arn
  alert_emails = var.alert_emails

  apps_namespace = module.apps.namespace
  app_services   = module.apps.service_names

  rag_enabled           = var.rag.enabled
  rag_namespace         = var.rag.namespace
  rag_node_asg_name     = module.eks_cluster.rag_node_asg_name
  rag_metrics_namespace = local.rag_metrics_namespace

  db_instance_id      = module.data_stores.db_instance_id
  redis_cluster_ids   = module.data_stores.redis_member_cluster_ids
  enable_alb_alarms   = var.enable_alb_alarms
  ingress_group_names = values(local.ingress_group)
}

module "backup" {
  source = "./modules/backup"
  count  = var.rag.enabled && var.rag_backup_retention_days > 0 ? 1 : 0

  name_prefix    = local.name_prefix
  kms_key_arn    = module.kms.key_arn
  retention_days = var.rag_backup_retention_days
  selection_tag  = module.eks_platform.rag_backup_tag
}

module "cicd" {
  source = "./modules/cicd"
  count  = var.github_org != "" ? 1 : 0

  name_prefix          = local.name_prefix
  cluster_name         = module.eks_cluster.cluster_name
  cluster_arn          = module.eks_cluster.cluster_arn
  ecr_repository_arns  = values(module.registry.repository_arns)
  deploy_namespaces    = compact([module.apps.namespace, var.rag.enabled ? var.rag.namespace : ""])
  github_org           = var.github_org
  github_deploy_repos  = var.github_deploy_repos
  create_oidc_provider = var.create_github_oidc_provider

  depends_on = [module.rag]
}
