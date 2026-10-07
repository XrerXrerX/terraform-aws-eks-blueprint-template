# ---------------------------------------------------------------------------
# EKS cluster with TWO deliberately different node pools:
#
#   general — every stateless app. Cluster-Autoscaler-managed (discovery tags
#             below), spread across all private subnets / AZs.
#
#   rag     — a DEDICATED node for the stateful RAG / vector-DB pod, outside
#             the general pod pool:
#               * fixed size (min = max = desired = 1), never autoscaled
#               * NO Cluster Autoscaler discovery tags, so CA never sees it
#               * tainted workload=rag:NoSchedule, so nothing else lands here
#               * pinned to ONE subnet/AZ, because its EBS volumes are AZ-bound
#             A ReadWriteOnce volume detached mid-write because an autoscaler
#             decided the node was "underutilized" is exactly how a vector
#             index gets corrupted. Isolation is the whole point.
# ---------------------------------------------------------------------------

locals {
  # The module ignores `disk_size` when it manages the launch template (its
  # default), so root volumes must go through block_device_mappings or nodes
  # silently get 20 GiB.
  general_root_volume = {
    xvda = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = var.general_node_group.disk_size_gb
        volume_type           = "gp3"
        encrypted             = true
        delete_on_termination = true
      }
    }
  }

  rag_root_volume = {
    xvda = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = var.rag_node_disk_size_gb
        volume_type           = "gp3"
        encrypted             = true
        delete_on_termination = true
      }
    }
  }

  node_groups = merge(
    {
      general = {
        instance_types        = var.general_node_group.instance_types
        capacity_type         = var.general_node_group.capacity_type
        min_size              = var.general_node_group.min_size
        max_size              = var.general_node_group.max_size
        desired_size          = var.general_node_group.desired_size
        block_device_mappings = local.general_root_volume

        update_config = { max_unavailable = 1 }
        labels        = { role = "general" }
        tags          = { Name = "${var.name_prefix}-node-general" }
      }
    },
    var.rag_enabled ? {
      rag = {
        instance_types        = [var.rag_node_instance_type]
        ami_type              = var.rag_node_ami_type
        capacity_type         = "ON_DEMAND" # never Spot: an interruption detaches the volumes
        min_size              = 1
        max_size              = 1
        desired_size          = 1
        subnet_ids            = [var.rag_subnet_id]
        block_device_mappings = local.rag_root_volume

        taints = {
          dedicated = {
            key    = "workload"
            value  = "rag"
            effect = "NO_SCHEDULE"
          }
        }

        # Single node: replacing it means RAG downtime while the volumes
        # re-attach. Unavoidable for a single-writer workload.
        update_config = { max_unavailable = 1 }
        labels        = { role = "rag" }
        tags          = { Name = "${var.name_prefix}-node-rag" }
      }
    } : {}
  )

  admin_access_entries = {
    for i, arn in var.cluster_admin_principal_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cloudwatch_addon = var.enable_container_insights ? {
    amazon-cloudwatch-observability = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.cloudwatch_agent[0].arn
      # The add-on default turns on enhanced Container Insights + Application
      # Signals, which is billed per observation and adds up quickly. Standard
      # metrics are enough for every alarm in modules/observability.
      configuration_values = jsonencode({
        agent = {
          config = {
            logs = {
              metrics_collected = {
                kubernetes = {
                  cluster_name                = var.cluster_name
                  enhanced_container_insights = false
                  accelerated_compute_metrics = false
                }
              }
            }
          }
        }
      })
    }
  } : {}
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.31.6" # exact pin: module majors change node/IAM defaults

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids # nodes and pods: private subnets only

  # Private endpoint always on. The public one is optional and CIDR-limited;
  # authentication is IAM + Access Entries either way.
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  cluster_enabled_log_types              = var.cluster_log_types
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_kms_key_id        = var.kms_key_arn

  # Envelope-encrypt Kubernetes Secrets with the platform key. create_kms_key
  # = false, otherwise the module silently creates a second, unused key.
  create_kms_key = false
  cluster_encryption_config = {
    provider_key_arn = var.kms_key_arn
    resources        = ["secrets"]
  }

  enable_irsa = true

  # Access Entries, not the legacy aws-auth ConfigMap.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin
  access_entries                           = local.admin_access_entries

  # The EKS metrics-server add-on listens on 10251. The managed control plane
  # probes it from the cluster SG; without this rule `kubectl top` fails and
  # every HPA sits at <unknown>.
  node_security_group_additional_rules = {
    metrics_server = {
      description                   = "Cluster API to metrics-server"
      protocol                      = "tcp"
      from_port                     = 10251
      to_port                       = 10251
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  eks_managed_node_group_defaults = {
    ami_type          = "AL2023_x86_64_STANDARD"
    capacity_type     = "ON_DEMAND"
    enable_monitoring = true
    version           = var.node_version

    # IMDSv2 only. Hop limit 1 additionally blocks non-hostNetwork pods from
    # the node's instance credentials (see var.node_imds_hop_limit).
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = var.node_imds_hop_limit
    }

    # Shell access through SSM Session Manager: no SSH keys, no port 22.
    iam_role_additional_policies = {
      ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  eks_managed_node_groups = local.node_groups

  cluster_addons = merge(
    {
      vpc-cni = {
        most_recent    = true
        before_compute = true
        # Required for the NetworkPolicies in modules/apps and modules/rag.
        # Without it the objects apply but nothing is enforced.
        configuration_values = jsonencode({
          enableNetworkPolicy = "true"
        })
      }
      kube-proxy = {
        most_recent = true
      }
      coredns = {
        most_recent = true
        configuration_values = jsonencode({
          replicaCount = 2
        })
      }
      # Required by every HPA. EKS does not ship it by default.
      metrics-server = {
        most_recent = true
      }
      aws-ebs-csi-driver = {
        most_recent              = true
        service_account_role_arn = aws_iam_role.ebs_csi.arn
      }
    },
    local.cloudwatch_addon
  )

  tags = { Name = var.cluster_name }
}

# ---------------------------------------------------------------------------
# Cluster Autoscaler discovery tags — ONLY on the general pool's ASG. The
# managed-node-group submodule cannot tag the EKS-owned ASG (and an unknown
# key in its `any`-typed map is dropped silently), hence separate resources.
# ---------------------------------------------------------------------------
resource "aws_autoscaling_group_tag" "cluster_autoscaler" {
  for_each = {
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }

  autoscaling_group_name = module.eks.eks_managed_node_groups["general"].node_group_autoscaling_group_names[0]

  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = false
  }
}

# Container Insights log groups, owned here so retention + KMS are enforced.
# Otherwise the agent creates them itself with no retention and no encryption.
# These are created in seconds while the agent only starts after the cluster
# and nodes exist (~15 min), so there is no practical race. If you enable
# Container Insights on an EXISTING cluster, import the groups first:
#   terraform import 'module.eks_cluster.aws_cloudwatch_log_group.container_insights["application"]' \
#     /aws/containerinsights/<cluster>/application
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = var.enable_container_insights ? toset(["application", "dataplane", "host", "performance"]) : toset([])

  name              = "/aws/containerinsights/${var.cluster_name}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}
